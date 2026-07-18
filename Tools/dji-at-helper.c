#include <errno.h>
#include <libusb.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DJI_VENDOR_ID 0x2ca3
#define DJI_PRODUCT_ID 0x4006
#define QUECTEL_VENDOR_ID 0x2c7c
#define QUECTEL_PRODUCT_ID 0x0125
#define DJI_AT_INTERFACE 3
#define RESPONSE_CAPACITY (256 * 1024)

typedef struct {
    libusb_context *context;
    libusb_device_handle *handle;
    int interface_number;
    unsigned char in_endpoint;
    unsigned char out_endpoint;
} dji_modem;

static long long monotonic_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

static int configure_transport(dji_modem *modem, int interface_number) {
    struct libusb_config_descriptor *configuration = NULL;
    int result = libusb_get_active_config_descriptor(
        libusb_get_device(modem->handle),
        &configuration
    );
    if (result != LIBUSB_SUCCESS) {
        fprintf(stderr, "read USB configuration: %s\n", libusb_error_name(result));
        return result;
    }

    bool found_interface = false;
    for (uint8_t index = 0; index < configuration->bNumInterfaces; index++) {
        const struct libusb_interface *interface = &configuration->interface[index];
        for (int alternate = 0; alternate < interface->num_altsetting; alternate++) {
            const struct libusb_interface_descriptor *descriptor =
                &interface->altsetting[alternate];
            if (descriptor->bInterfaceNumber != interface_number) {
                continue;
            }

            found_interface = true;
            for (uint8_t endpoint_index = 0;
                 endpoint_index < descriptor->bNumEndpoints;
                 endpoint_index++) {
                const struct libusb_endpoint_descriptor *endpoint =
                    &descriptor->endpoint[endpoint_index];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) !=
                    LIBUSB_TRANSFER_TYPE_BULK) {
                    continue;
                }
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                    LIBUSB_ENDPOINT_IN) {
                    modem->in_endpoint = endpoint->bEndpointAddress;
                } else {
                    modem->out_endpoint = endpoint->bEndpointAddress;
                }
            }
        }
    }
    libusb_free_config_descriptor(configuration);

    if (!found_interface || modem->in_endpoint == 0 || modem->out_endpoint == 0) {
        fprintf(stderr, "interface %d has no bulk AT transport\n", interface_number);
        return LIBUSB_ERROR_NOT_FOUND;
    }
    modem->interface_number = interface_number;
    return LIBUSB_SUCCESS;
}

static void close_modem(dji_modem *modem) {
    if (modem->handle != NULL) {
        libusb_release_interface(modem->handle, modem->interface_number);
        libusb_close(modem->handle);
    }
    /*
     * This helper is a short-lived process. On macOS, libusb_exit() can
     * deadlock with the hotplug thread when the modem disappears during a
     * reboot. The OS reclaims the context at process exit, so deliberately
     * leave it alive after closing the device handle.
     */
    memset(modem, 0, sizeof(*modem));
}

static int open_modem(dji_modem *modem) {
    memset(modem, 0, sizeof(*modem));

    int result = libusb_init(&modem->context);
    if (result != LIBUSB_SUCCESS) {
        fprintf(stderr, "libusb_init: %s\n", libusb_error_name(result));
        return result;
    }

    modem->handle = libusb_open_device_with_vid_pid(
        modem->context,
        DJI_VENDOR_ID,
        DJI_PRODUCT_ID
    );
    if (modem->handle == NULL) {
        modem->handle = libusb_open_device_with_vid_pid(
            modem->context,
            QUECTEL_VENDOR_ID,
            QUECTEL_PRODUCT_ID
        );
    }
    if (modem->handle == NULL) {
        fprintf(
            stderr,
            "DJI IG830 USB device was not found (2ca3:4006 or 2c7c:0125).\n"
        );
        close_modem(modem);
        return LIBUSB_ERROR_NO_DEVICE;
    }

    int interface_number = DJI_AT_INTERFACE;
    const char *interface_override = getenv("DJI_AT_INTERFACE");
    if (interface_override != NULL && interface_override[0] != '\0') {
        char *end = NULL;
        long parsed = strtol(interface_override, &end, 10);
        if (end == interface_override || *end != '\0' || parsed < 0 || parsed > 255) {
            fprintf(stderr, "invalid DJI_AT_INTERFACE: %s\n", interface_override);
            close_modem(modem);
            return LIBUSB_ERROR_INVALID_PARAM;
        }
        interface_number = (int)parsed;
    }

    result = configure_transport(modem, interface_number);
    if (result != LIBUSB_SUCCESS) {
        close_modem(modem);
        return result;
    }

    const char *allow_detach = getenv("DJI_AT_ALLOW_DETACH");
    if (allow_detach != NULL && strcmp(allow_detach, "1") == 0) {
        (void)libusb_set_auto_detach_kernel_driver(modem->handle, 1);
    }
    result = libusb_claim_interface(modem->handle, modem->interface_number);
    if (result != LIBUSB_SUCCESS) {
        fprintf(stderr, "claim interface %d: %s\n", modem->interface_number, libusb_error_name(result));
        close_modem(modem);
        return result;
    }
    return LIBUSB_SUCCESS;
}

static void drain_input(dji_modem *modem) {
    unsigned char buffer[4096];
    int transferred = 0;
    while (libusb_bulk_transfer(
               modem->handle,
               modem->in_endpoint,
               buffer,
               (int)sizeof(buffer),
               &transferred,
               20
           ) == LIBUSB_SUCCESS) {
    }
}

static bool response_is_complete(const char *response) {
    return strstr(response, "\r\nOK\r\n") != NULL ||
           strstr(response, "\nOK\n") != NULL ||
           strstr(response, "\r\nERROR\r\n") != NULL ||
           strstr(response, "+CME ERROR:") != NULL ||
           strstr(response, "+CMS ERROR:") != NULL;
}

static int run_at_command(
    dji_modem *modem,
    const char *command,
    unsigned int total_timeout_ms,
    char *response,
    size_t response_capacity
) {
    if (response_capacity == 0) {
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    response[0] = '\0';
    drain_input(modem);

    size_t command_length = strlen(command);
    char *wire_command = malloc(command_length + 3);
    if (wire_command == NULL) {
        return LIBUSB_ERROR_NO_MEM;
    }
    memcpy(wire_command, command, command_length);
    memcpy(wire_command + command_length, "\r\n", 3);

    int transferred = 0;
    int result = libusb_bulk_transfer(
        modem->handle,
        modem->out_endpoint,
        (unsigned char *)wire_command,
        (int)command_length + 2,
        &transferred,
        1500
    );
    free(wire_command);
    if (result != LIBUSB_SUCCESS) {
        return result;
    }

    size_t used = 0;
    long long deadline = monotonic_milliseconds() + total_timeout_ms;
    long long completed_at = 0;
    while (monotonic_milliseconds() < deadline && used + 1 < response_capacity) {
        unsigned char buffer[4096];
        int received = 0;
        result = libusb_bulk_transfer(
            modem->handle,
            modem->in_endpoint,
            buffer,
            (int)sizeof(buffer),
            &received,
            180
        );
        if (result == LIBUSB_SUCCESS && received > 0) {
            size_t remaining = response_capacity - used - 1;
            size_t copy_length = (size_t)received < remaining ? (size_t)received : remaining;
            memcpy(response + used, buffer, copy_length);
            used += copy_length;
            response[used] = '\0';
            if (response_is_complete(response)) {
                completed_at = monotonic_milliseconds();
            }
            continue;
        }
        if (result != LIBUSB_ERROR_TIMEOUT) {
            return result;
        }
        if (completed_at != 0 && monotonic_milliseconds() - completed_at >= 150) {
            break;
        }
    }
    response[used] = '\0';
    return LIBUSB_SUCCESS;
}

static int print_section(
    dji_modem *modem,
    const char *name,
    const char *command,
    unsigned int timeout_ms
) {
    char *response = calloc(RESPONSE_CAPACITY, 1);
    if (response == NULL) {
        fprintf(stderr, "Out of memory.\n");
        return LIBUSB_ERROR_NO_MEM;
    }

    int result = run_at_command(modem, command, timeout_ms, response, RESPONSE_CAPACITY);
    printf("@@BEGIN %s\n", name);
    if (result == LIBUSB_SUCCESS) {
        fputs(response, stdout);
        if (response[0] != '\0' && response[strlen(response) - 1] != '\n') {
            fputc('\n', stdout);
        }
    } else {
        printf("TRANSPORT_ERROR: %s\n", libusb_error_name(result));
    }
    printf("@@END %s\n", name);
    fflush(stdout);
    free(response);
    return result;
}

static int run_status(dji_modem *modem) {
    static const struct {
        const char *name;
        const char *command;
        unsigned int timeout_ms;
    } commands[] = {
        {"AT", "AT", 1500},
        {"IDENTITY", "ATI", 1800},
        {"SIM_PIN", "AT+CPIN?", 1800},
        {"SIM_STATE", "AT+QSIMSTAT?", 1800},
        {"ICCID", "AT+QCCID", 1800},
        {"OPERATOR", "AT+COPS?", 1800},
        {"EPS_REGISTRATION", "AT+CEREG?", 1800},
        {"PACKET_REGISTRATION", "AT+CGREG?", 1800},
        {"SIGNAL", "AT+CSQ", 1800},
        {"NETWORK_INFO", "AT+QNWINFO", 1800},
        {"SERVING_CELL", "AT+QENG=\"servingcell\"", 3000},
        {"PDP_ADDRESS", "AT+CGPADDR=1", 1800},
        {"WWAN_STATUS", "AT+QLWWANSTATUS=1", 1800},
        {"NETDEV_STATUS", "AT+QNETDEVSTATUS?", 1800},
        {"IMS_CONFIG", "AT+QCFG=\"ims\"", 1800},
        {"VOLTE_CONFIG", "AT+QCFG=\"volte/disable\"", 1800},
        {"CALL_CONTROL", "AT+QCFG=\"call_control\"", 1800},
        {"PHONE_NUMBER", "AT+CNUM", 1800},
        {"LED_MODE", "AT+QCFG=\"ledmode\"", 1800},
        {"USB_MODE", "AT+QCFG=\"usbnet\"", 1800},
    };

    int successful = 0;
    size_t count = sizeof(commands) / sizeof(commands[0]);
    for (size_t index = 0; index < count; index++) {
        if (print_section(
                modem,
                commands[index].name,
                commands[index].command,
                commands[index].timeout_ms
            ) == LIBUSB_SUCCESS) {
            successful++;
        }
    }
    return successful > 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

static void print_usage(const char *program) {
    fprintf(stderr, "Usage: %s detect|status|neighbors|operators|raw <AT command>\n", program);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(argv[0]);
        return EXIT_FAILURE;
    }

    dji_modem modem;
    if (open_modem(&modem) != LIBUSB_SUCCESS) {
        return 2;
    }

    int exit_code = EXIT_SUCCESS;
    if (strcmp(argv[1], "detect") == 0) {
        exit_code = print_section(&modem, "IDENTITY", "ATI", 1800) == LIBUSB_SUCCESS
            ? EXIT_SUCCESS
            : EXIT_FAILURE;
    } else if (strcmp(argv[1], "status") == 0) {
        exit_code = run_status(&modem);
    } else if (strcmp(argv[1], "neighbors") == 0) {
        exit_code = print_section(
            &modem,
            "NEIGHBOR_CELLS",
            "AT+QENG=\"neighbourcell\"",
            6000
        ) == LIBUSB_SUCCESS ? EXIT_SUCCESS : EXIT_FAILURE;
    } else if (strcmp(argv[1], "operators") == 0) {
        exit_code = print_section(&modem, "OPERATORS", "AT+COPS=?", 180000) == LIBUSB_SUCCESS
            ? EXIT_SUCCESS
            : EXIT_FAILURE;
    } else if (strcmp(argv[1], "raw") == 0 && argc >= 3) {
        exit_code = print_section(&modem, "RAW", argv[2], 30000) == LIBUSB_SUCCESS
            ? EXIT_SUCCESS
            : EXIT_FAILURE;
    } else {
        print_usage(argv[0]);
        exit_code = EXIT_FAILURE;
    }

    close_modem(&modem);
    return exit_code;
}
