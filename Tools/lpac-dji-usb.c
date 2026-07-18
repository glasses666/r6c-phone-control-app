#include <driver.h>
#include <euicc/euicc.h>
#include <euicc/hexutil.h>
#include <euicc/interface.h>

#include <libusb.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DJI_VENDOR_ID 0x2ca3
#define DJI_PRODUCT_ID 0x4006
#define QUECTEL_VENDOR_ID 0x2c7c
#define QUECTEL_PRODUCT_ID 0x0125
#define AT_INTERFACE 3
#define RESPONSE_CAPACITY (256 * 1024)

struct dji_usb_userdata {
    libusb_context *context;
    libusb_device_handle *handle;
    int interface_number;
    unsigned char in_endpoint;
    unsigned char out_endpoint;
};

static long long monotonic_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

static void close_modem(struct dji_usb_userdata *userdata) {
    if (userdata->handle != NULL) {
        libusb_release_interface(userdata->handle, userdata->interface_number);
        libusb_close(userdata->handle);
        userdata->handle = NULL;
    }
    if (userdata->context != NULL) {
        libusb_exit(userdata->context);
        userdata->context = NULL;
    }
}

static int configure_transport(struct dji_usb_userdata *userdata, int interface_number) {
    struct libusb_config_descriptor *configuration = NULL;
    int result = libusb_get_active_config_descriptor(
        libusb_get_device(userdata->handle),
        &configuration
    );
    if (result != LIBUSB_SUCCESS) {
        fprintf(stderr, "read USB configuration: %s\n", libusb_error_name(result));
        return -1;
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
                    userdata->in_endpoint = endpoint->bEndpointAddress;
                } else {
                    userdata->out_endpoint = endpoint->bEndpointAddress;
                }
            }
        }
    }
    libusb_free_config_descriptor(configuration);

    if (!found_interface || userdata->in_endpoint == 0 || userdata->out_endpoint == 0) {
        fprintf(stderr, "interface %d has no bulk AT transport\n", interface_number);
        return -1;
    }
    userdata->interface_number = interface_number;
    return 0;
}

static int open_modem(struct dji_usb_userdata *userdata) {
    int result = libusb_init(&userdata->context);
    if (result != LIBUSB_SUCCESS) {
        fprintf(stderr, "libusb_init: %s\n", libusb_error_name(result));
        return -1;
    }

    userdata->handle = libusb_open_device_with_vid_pid(userdata->context, DJI_VENDOR_ID, DJI_PRODUCT_ID);
    if (userdata->handle == NULL) {
        userdata->handle = libusb_open_device_with_vid_pid(
            userdata->context,
            QUECTEL_VENDOR_ID,
            QUECTEL_PRODUCT_ID
        );
    }
    if (userdata->handle == NULL) {
        fprintf(stderr, "DJI IG830 USB device was not found (2ca3:4006 or 2c7c:0125).\n");
        close_modem(userdata);
        return -1;
    }

    int interface_number = AT_INTERFACE;
    const char *interface_override = getenv("DJI_AT_INTERFACE");
    if (interface_override != NULL && interface_override[0] != '\0') {
        char *end = NULL;
        long parsed = strtol(interface_override, &end, 10);
        if (end == interface_override || *end != '\0' || parsed < 0 || parsed > 255) {
            fprintf(stderr, "invalid DJI_AT_INTERFACE: %s\n", interface_override);
            close_modem(userdata);
            return -1;
        }
        interface_number = (int)parsed;
    }
    if (configure_transport(userdata, interface_number) != 0) {
        close_modem(userdata);
        return -1;
    }

    const char *allow_detach = getenv("DJI_AT_ALLOW_DETACH");
    if (allow_detach != NULL && strcmp(allow_detach, "1") == 0) {
        (void)libusb_set_auto_detach_kernel_driver(userdata->handle, 1);
    }
    result = libusb_claim_interface(userdata->handle, userdata->interface_number);
    if (result != LIBUSB_SUCCESS) {
        fprintf(
            stderr,
            "claim interface %d: %s\n",
            userdata->interface_number,
            libusb_error_name(result)
        );
        close_modem(userdata);
        return -1;
    }
    return 0;
}

static void drain_input(struct dji_usb_userdata *userdata) {
    unsigned char buffer[4096];
    int transferred = 0;
    while (libusb_bulk_transfer(
               userdata->handle,
               userdata->in_endpoint,
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
    struct dji_usb_userdata *userdata,
    const char *command,
    unsigned int total_timeout_ms,
    char *response,
    size_t response_capacity
) {
    response[0] = '\0';
    drain_input(userdata);

    size_t command_length = strlen(command);
    char *wire_command = malloc(command_length + 3);
    if (wire_command == NULL) {
        return -1;
    }
    memcpy(wire_command, command, command_length);
    memcpy(wire_command + command_length, "\r\n", 3);

    int transferred = 0;
    int result = libusb_bulk_transfer(
        userdata->handle,
        userdata->out_endpoint,
        (unsigned char *)wire_command,
        (int)command_length + 2,
        &transferred,
        1500
    );
    free(wire_command);
    if (result != LIBUSB_SUCCESS) {
        return -1;
    }

    size_t used = 0;
    long long deadline = monotonic_milliseconds() + total_timeout_ms;
    long long completed_at = 0;
    while (monotonic_milliseconds() < deadline && used + 1 < response_capacity) {
        unsigned char buffer[4096];
        int received = 0;
        result = libusb_bulk_transfer(
            userdata->handle,
            userdata->in_endpoint,
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
            return -1;
        }
        if (completed_at != 0 && monotonic_milliseconds() - completed_at >= 150) {
            break;
        }
    }

    return response_is_complete(response) && strstr(response, "ERROR") == NULL ? 0 : -1;
}

static int transmit_apdu(
    struct dji_usb_userdata *userdata,
    uint8_t **rx,
    uint32_t *rx_len,
    const uint8_t *tx,
    uint32_t tx_len
) {
    *rx = NULL;
    *rx_len = 0;

    char *encoded = malloc((size_t)tx_len * 2 + 1);
    if (encoded == NULL) {
        return -1;
    }
    if (euicc_hexutil_bin2hex(encoded, (size_t)tx_len * 2 + 1, tx, tx_len) < 0) {
        free(encoded);
        return -1;
    }

    size_t command_capacity = strlen(encoded) + 48;
    char *command = malloc(command_capacity);
    char *response = calloc(RESPONSE_CAPACITY, 1);
    if (command == NULL || response == NULL) {
        free(encoded);
        free(command);
        free(response);
        return -1;
    }
    snprintf(command, command_capacity, "AT+CSIM=%u,\"%s\"", tx_len * 2, encoded);
    free(encoded);

    if (run_at_command(userdata, command, 120000, response, RESPONSE_CAPACITY) != 0) {
        free(command);
        free(response);
        return -1;
    }
    free(command);

    char *csim = strstr(response, "+CSIM:");
    if (csim == NULL) {
        free(response);
        return -1;
    }
    char *first_quote = strchr(csim, '"');
    char *last_quote = first_quote == NULL ? NULL : strchr(first_quote + 1, '"');
    if (first_quote == NULL || last_quote == NULL || last_quote <= first_quote + 1) {
        free(response);
        return -1;
    }

    size_t hex_length = (size_t)(last_quote - first_quote - 1);
    if (hex_length % 2 != 0) {
        free(response);
        return -1;
    }
    *rx_len = (uint32_t)(hex_length / 2);
    *rx = malloc(*rx_len);
    if (*rx == NULL || euicc_hexutil_hex2bin_r(*rx, *rx_len, first_quote + 1, hex_length) < 0) {
        free(*rx);
        *rx = NULL;
        *rx_len = 0;
        free(response);
        return -1;
    }

    free(response);
    return 0;
}

static int apdu_interface_connect(struct euicc_ctx *ctx) {
    struct dji_usb_userdata *userdata = ctx->apdu.interface->userdata;
    if (open_modem(userdata) != 0) {
        return -1;
    }

    char response[4096];
    if (run_at_command(userdata, "AT", 3000, response, sizeof(response)) != 0 ||
        run_at_command(userdata, "AT+CSIM=?", 3000, response, sizeof(response)) != 0) {
        close_modem(userdata);
        return -1;
    }
    return 0;
}

static void apdu_interface_disconnect(struct euicc_ctx *ctx) {
    struct dji_usb_userdata *userdata = ctx->apdu.interface->userdata;
    close_modem(userdata);
}

static int apdu_interface_transmit(
    struct euicc_ctx *ctx,
    uint8_t **rx,
    uint32_t *rx_len,
    const uint8_t *tx,
    uint32_t tx_len
) {
    struct dji_usb_userdata *userdata = ctx->apdu.interface->userdata;
    return transmit_apdu(userdata, rx, rx_len, tx, tx_len);
}

static int apdu_interface_logic_channel_open(struct euicc_ctx *ctx, const uint8_t *aid, uint8_t aid_len) {
    static const uint8_t manage_open[] = {0x00, 0x70, 0x00, 0x00, 0x01};
    uint8_t *response = NULL;
    uint32_t response_len = 0;
    if (apdu_interface_transmit(ctx, &response, &response_len, manage_open, sizeof(manage_open)) != 0 ||
        response_len != 3 || response[1] != 0x90 || response[2] != 0x00) {
        free(response);
        return -1;
    }
    uint8_t channel = response[0];
    free(response);

    uint8_t *select = malloc((size_t)aid_len + 5);
    if (select == NULL) {
        return -1;
    }
    select[0] = channel;
    select[1] = 0xA4;
    select[2] = 0x04;
    select[3] = 0x00;
    select[4] = aid_len;
    memcpy(select + 5, aid, aid_len);

    response = NULL;
    response_len = 0;
    int result = apdu_interface_transmit(ctx, &response, &response_len, select, (uint32_t)aid_len + 5);
    free(select);
    if (result != 0 || response_len < 2 ||
        (response[response_len - 2] != 0x90 && response[response_len - 2] != 0x61)) {
        free(response);
        return -1;
    }
    free(response);
    return channel;
}

static void apdu_interface_logic_channel_close(struct euicc_ctx *ctx, uint8_t channel) {
    const uint8_t manage_close[] = {0x00, 0x70, 0x80, channel, 0x00};
    uint8_t *response = NULL;
    uint32_t response_len = 0;
    (void)apdu_interface_transmit(ctx, &response, &response_len, manage_close, sizeof(manage_close));
    free(response);
}

static int libapduinterface_init(struct euicc_apdu_interface *interface) {
    struct dji_usb_userdata *userdata = calloc(1, sizeof(*userdata));
    if (userdata == NULL) {
        return -1;
    }

    memset(interface, 0, sizeof(*interface));
    interface->connect = apdu_interface_connect;
    interface->disconnect = apdu_interface_disconnect;
    interface->logic_channel_open = apdu_interface_logic_channel_open;
    interface->logic_channel_close = apdu_interface_logic_channel_close;
    interface->transmit = apdu_interface_transmit;
    interface->userdata = userdata;
    return 0;
}

static void libapduinterface_fini(struct euicc_apdu_interface *interface) {
    struct dji_usb_userdata *userdata = interface->userdata;
    if (userdata != NULL) {
        close_modem(userdata);
        free(userdata);
    }
    interface->userdata = NULL;
}

DRIVER_INTERFACE = {
    .type = DRIVER_APDU,
    .name = "dji_usb",
    .init = (int (*)(void *))libapduinterface_init,
    .main = NULL,
    .fini = (void (*)(void *))libapduinterface_fini,
};
