package im.dracoglasser.euicccli;

import android.os.Binder;
import android.os.IBinder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy.Type;
import java.net.URI;
import java.net.URL;
import java.net.URLConnection;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;

public final class EuiccAppProcessCli {
    private static final String DEFAULT_PACKAGE = "im.angry.easyeuicc";
    private static final String DEFAULT_READER = "SIM1";
    private static final byte[][] KNOWN_ISDR_AIDS = new byte[][] {
        hex("A0000005591010FFFFFFFF8900000100"),
        hex("A0000005591010000000008900000300"),
        hex("A0000005591010FFFFFFFF8900050500"),
        hex("A0000005591010FFFFFFFF8900000177"),
        hex("A000000559104C696E6B736669656C64"),
        hex("A06573746B6D65FFFF4953442D522030"),
        hex("A06573746B6D65FFFF4953442D522031"),
        hex("A06573746B6D65FFFFFFFF4953442D52")
    };

    private String packageName = DEFAULT_PACKAGE;
    private String readerName = DEFAULT_READER;
    private String imei;
    private String apkPath;
    private String libraryPath;
    private ClassLoader appClassLoader;
    private Object secureElementService;
    private HttpHandler currentHttpHandler;

    public static void main(String[] args) {
        try {
            new EuiccAppProcessCli().run(args);
        } catch (Throwable t) {
            JSONObject error = new JSONObject();
            try {
                error.put("ok", false)
                    .put("error", t.getClass().getSimpleName())
                    .put("message", String.valueOf(t.getMessage()));
            } catch (Exception ignored) {
            }
            System.err.println(error.toString());
            t.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private void run(String[] args) throws Exception {
        List<String> argv = parseGlobalArgs(args);
        if (argv.isEmpty() || "help".equals(argv.get(0)) || "--help".equals(argv.get(0))) {
            usage();
            return;
        }
        if ("debug-interfaces".equals(argv.get(0))) {
            printHiddenInterfaces();
            return;
        }

        String cmd = argv.get(0);
        if ("download-dry-run".equals(cmd) || "download-parse".equals(cmd)) {
            requireArg(argv, 1, "activation code");
            printActivationParse(argv.get(1), true);
            return;
        }
        if ("net-probe".equals(cmd)) {
            netProbe(argv.subList(1, argv.size()));
            return;
        }
        if ("dns-proxy".equals(cmd)) {
            dnsProxy(argv.subList(1, argv.size()));
            return;
        }

        initClassLoader();
        connectSecureElementService();
        if ("list".equals(cmd)) {
            printProfilesText(openWorkingLpa().profiles);
        } else if ("list-json".equals(cmd) || "json".equals(cmd)) {
            System.out.println(profilesJson(openWorkingLpa().profiles).toString());
        } else if ("switch".equals(cmd)) {
            requireArg(argv, 1, "switch target");
            switchTarget(argv.get(1), false, null);
        } else if ("switch-iccid".equals(cmd)) {
            requireArg(argv, 1, "iccid");
            switchTarget(argv.get(1), true, null);
        } else if ("switch-exact".equals(cmd)) {
            requireArg(argv, 1, "profile name");
            switchTarget(argv.get(1), false, argv.size() > 2 ? argv.get(2) : "");
        } else if ("download".equals(cmd)) {
            requireArg(argv, 1, "activation code");
            downloadProfile(argv.get(1), argv.size() > 2 ? argv.get(2) : "");
        } else {
            throw new IllegalArgumentException("unknown command: " + cmd);
        }
    }

    private List<String> parseGlobalArgs(String[] args) {
        ArrayList<String> rest = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--package".equals(arg)) {
                packageName = args[++i];
            } else if ("--reader".equals(arg)) {
                readerName = args[++i];
            } else if ("--apk".equals(arg)) {
                apkPath = args[++i];
            } else if ("--lib-dir".equals(arg)) {
                libraryPath = args[++i];
            } else if ("--imei".equals(arg)) {
                imei = args[++i];
            } else {
                rest.add(arg);
            }
        }
        return rest;
    }

    private static void usage() {
        System.out.println("Usage: app_process ... " + EuiccAppProcessCli.class.getName() +
            " [--package im.angry.easyeuicc] [--reader SIM1] [--apk /path/base.apk] [--lib-dir native-path] [--imei imei] list|list-json|switch <target>|switch-iccid <iccid>|switch-exact <name> [provider]|download-dry-run <LPA>|download <LPA> [confirmation-code]|net-probe <host-or-url>...|dns-proxy [bind-address] [port]");
    }

    private static void netProbe(List<String> targets) throws Exception {
        if (targets.isEmpty()) {
            targets = Arrays.asList(
                "http://connect.rom.miui.com/generate_204",
                "http://www.baidu.com",
                "https://www.cloudflare.com/cdn-cgi/trace",
                "https://chatgpt.com"
            );
        }
        JSONArray results = new JSONArray();
        for (String target : targets) {
            results.put(probeTarget(target));
        }
        JSONObject output = new JSONObject();
        output.put("ok", true);
        output.put("results", results);
        System.out.println(output.toString());
    }

    private static JSONObject probeTarget(String target) throws Exception {
        JSONObject result = new JSONObject();
        result.put("target", target);
        String urlText = target.contains("://") ? target : "https://" + target;
        URL url = new URL(urlText);
        String host = url.getHost();
        result.put("host", host);
        JSONArray addresses = new JSONArray();
        try {
            for (InetAddress address : InetAddress.getAllByName(host)) {
                addresses.put(address.getHostAddress());
            }
            result.put("dnsOk", true);
            result.put("addresses", addresses);
        } catch (Throwable t) {
            result.put("dnsOk", false);
            result.put("dnsError", t.getClass().getSimpleName() + ": " + t.getMessage());
            return result;
        }

        try {
            HttpURLConnection conn = (HttpURLConnection) url.openConnection(java.net.Proxy.NO_PROXY);
            conn.setRequestMethod("HEAD");
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(6000);
            conn.setReadTimeout(8000);
            result.put("httpStatus", conn.getResponseCode());
            result.put("finalUrl", conn.getURL().toString());
            result.put("contentType", conn.getContentType());
            conn.disconnect();
        } catch (Throwable t) {
            result.put("httpError", t.getClass().getSimpleName() + ": " + t.getMessage());
        }
        return result;
    }

    private static void dnsProxy(List<String> args) throws Exception {
        String bindAddress = args.isEmpty() ? "127.0.0.1" : args.get(0);
        int port = args.size() > 1 ? Integer.parseInt(args.get(1)) : 53;
        DatagramSocket socket = new DatagramSocket(new InetSocketAddress(bindAddress, port));
        byte[] buf = new byte[1500];
        System.out.println("dns-proxy listening " + bindAddress + ":" + port);
        while (true) {
            DatagramPacket packet = new DatagramPacket(buf, buf.length);
            socket.receive(packet);
            byte[] query = Arrays.copyOf(packet.getData(), packet.getLength());
            byte[] response;
            try {
                response = dnsResponse(query);
            } catch (Throwable t) {
                response = dnsErrorResponse(query, 2);
            }
            DatagramPacket reply = new DatagramPacket(response, response.length, packet.getAddress(), packet.getPort());
            socket.send(reply);
        }
    }

    private static byte[] dnsResponse(byte[] query) throws Exception {
        if (query.length < 12) {
            return dnsErrorResponse(query, 1);
        }
        int qd = u16(query, 4);
        if (qd < 1) {
            return dnsErrorResponse(query, 1);
        }
        int[] offset = new int[] { 12 };
        String name = readDnsName(query, offset);
        if (offset[0] + 4 > query.length) {
            return dnsErrorResponse(query, 1);
        }
        int qtype = u16(query, offset[0]);
        int questionEnd = offset[0] + 4;
        ArrayList<byte[]> records = new ArrayList<>();
        if (qtype == 1 || qtype == 28) {
            records.addAll(resolveHttpDns(name, qtype));
        }

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(query[0]);
        out.write(query[1]);
        putU16(out, 0x8180);
        putU16(out, 1);
        putU16(out, records.size());
        putU16(out, 0);
        putU16(out, 0);
        out.write(query, 12, questionEnd - 12);
        for (byte[] address : records) {
            out.write(0xC0);
            out.write(0x0C);
            putU16(out, qtype);
            putU16(out, 1);
            putU32(out, 120);
            putU16(out, address.length);
            out.write(address);
        }
        return out.toByteArray();
    }

    private static ArrayList<byte[]> resolveHttpDns(String name, int qtype) throws Exception {
        String type = qtype == 28 ? "AAAA" : "A";
        String urlText = "http://223.5.5.5/resolve?name=" +
            URLEncoder.encode(name, "UTF-8") + "&type=" + type;
        URLConnection raw = new URL(urlText).openConnection(java.net.Proxy.NO_PROXY);
        HttpURLConnection conn = (HttpURLConnection) raw;
        conn.setRequestProperty("Host", "dns.alidns.com");
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(7000);
        conn.setInstanceFollowRedirects(false);
        byte[] body = readAllOuter(conn.getInputStream());
        JSONObject json = new JSONObject(new String(body, StandardCharsets.UTF_8));
        ArrayList<byte[]> answers = new ArrayList<>();
        JSONArray records = json.optJSONArray("Answer");
        if (records == null) {
            return answers;
        }
        for (int i = 0; i < records.length(); i++) {
            JSONObject record = records.getJSONObject(i);
            if (record.optInt("type") != qtype) {
                continue;
            }
            String data = record.optString("data", "");
            if (data.isEmpty()) {
                continue;
            }
            answers.add(InetAddress.getByName(data).getAddress());
        }
        return answers;
    }

    private static byte[] dnsErrorResponse(byte[] query, int rcode) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(query.length > 0 ? query[0] : 0);
        out.write(query.length > 1 ? query[1] : 0);
        putU16(out, 0x8180 | (rcode & 0x0F));
        putU16(out, query.length >= 6 ? u16(query, 4) : 0);
        putU16(out, 0);
        putU16(out, 0);
        putU16(out, 0);
        if (query.length > 12) {
            out.write(query, 12, query.length - 12);
        }
        return out.toByteArray();
    }

    private static String readDnsName(byte[] data, int[] offset) {
        StringBuilder name = new StringBuilder();
        while (offset[0] < data.length) {
            int len = data[offset[0]++] & 0xFF;
            if (len == 0) {
                break;
            }
            if ((len & 0xC0) != 0 || offset[0] + len > data.length) {
                throw new IllegalArgumentException("unsupported DNS name encoding");
            }
            if (name.length() > 0) {
                name.append('.');
            }
            name.append(new String(data, offset[0], len, StandardCharsets.UTF_8));
            offset[0] += len;
        }
        return name.toString();
    }

    private static int u16(byte[] data, int offset) {
        return ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
    }

    private static void putU16(ByteArrayOutputStream out, int value) {
        out.write((value >> 8) & 0xFF);
        out.write(value & 0xFF);
    }

    private static void putU32(ByteArrayOutputStream out, long value) {
        out.write((int) ((value >> 24) & 0xFF));
        out.write((int) ((value >> 16) & 0xFF));
        out.write((int) ((value >> 8) & 0xFF));
        out.write((int) (value & 0xFF));
    }

    private static byte[] readAllOuter(InputStream in) throws Exception {
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) != -1) {
                bytes.write(buffer, 0, n);
            }
            return bytes.toByteArray();
        } finally {
            in.close();
        }
    }

    private static void printHiddenInterfaces() throws Exception {
        String[] names = new String[] {
            "android.se.omapi.ISecureElementService",
            "android.se.omapi.ISecureElementReader",
            "android.se.omapi.ISecureElementSession",
            "android.se.omapi.ISecureElementChannel",
            "android.se.omapi.ISecureElementListener"
        };
        for (String name : names) {
            Class<?> cls = Class.forName(name);
            System.out.println("## " + name);
            for (Method method : cls.getMethods()) {
                if (method.getDeclaringClass().getName().startsWith("android.se.omapi")) {
                    System.out.println(method.toString());
                }
            }
            for (Class<?> inner : cls.getDeclaredClasses()) {
                System.out.println("inner " + inner.getName() + " extends " + inner.getSuperclass());
            }
        }
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        Object binder = serviceManager.getMethod("getService", String.class).invoke(null, "secure_element");
        System.out.println("secure_element_binder=" + binder);
    }

    private static void requireArg(List<String> argv, int index, String name) {
        if (argv.size() <= index || argv.get(index).isEmpty()) {
            throw new IllegalArgumentException("missing " + name);
        }
    }

    private void initClassLoader() throws Exception {
        if (apkPath != null && !apkPath.isEmpty()) {
            Class<?> pathClassLoader = Class.forName("dalvik.system.PathClassLoader");
            appClassLoader = (ClassLoader) pathClassLoader
                .getConstructor(String.class, String.class, ClassLoader.class)
                .newInstance(apkPath, libraryPath == null ? "" : libraryPath, ClassLoader.getSystemClassLoader());
            return;
        }
        throw new IllegalArgumentException("--apk is required for direct app_process CLI");
    }

    private void connectSecureElementService() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) serviceManager.getMethod("getService", String.class).invoke(null, "secure_element");
        if (binder == null) {
            throw new IllegalStateException("secure_element service not found");
        }
        Class<?> stub = Class.forName("android.se.omapi.ISecureElementService$Stub");
        secureElementService = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
        String[] readers = (String[]) secureElementService.getClass().getMethod("getReaders").invoke(secureElementService);
        boolean found = false;
        for (String reader : readers) {
            if (readerName.equals(reader)) {
                found = true;
                break;
            }
        }
        if (!found) {
            throw new IllegalStateException("reader not found: " + readerName + " in " + Arrays.toString(readers));
        }
    }

    private LpaSession openWorkingLpa() throws Exception {
        Throwable last = null;
        for (byte[] aid : KNOWN_ISDR_AIDS) {
            OmapiHandler apdu = new OmapiHandler(secureElementService, readerName);
            try {
                Object lpa = newLocalProfileAssistant(aid, apdu);
                List<Profile> profiles = readProfiles(lpa);
                String eid = invokeString(lpa, "getEID");
                return new LpaSession(lpa, profiles, eid);
            } catch (Throwable t) {
                last = t;
                apdu.disconnectQuietly();
            }
        }
        throw new IllegalStateException("no usable ISD-R channel opened", last);
    }

    private Object newLocalProfileAssistant(byte[] aid, OmapiHandler apdu) throws Exception {
        Class<?> apduInterface = appClassLoader.loadClass("net.typeblog.lpac_jni.ApduInterface");
        Class<?> httpInterface = appClassLoader.loadClass("net.typeblog.lpac_jni.HttpInterface");
        Object apduProxy = Proxy.newProxyInstance(
            appClassLoader,
            new Class<?>[] { apduInterface },
            apdu
        );
        HttpHandler httpHandler = new HttpHandler(appClassLoader, packageName);
        currentHttpHandler = httpHandler;
        Object httpProxy = Proxy.newProxyInstance(
            appClassLoader,
            new Class<?>[] { httpInterface },
            httpHandler
        );
        Class<?> impl = appClassLoader.loadClass("net.typeblog.lpac_jni.impl.LocalProfileAssistantImpl");
        Constructor<?> ctor = impl.getConstructor(byte[].class, apduInterface, httpInterface);
        return ctor.newInstance(aid, apduProxy, httpProxy);
    }

    private List<Profile> readProfiles(Object lpa) throws Exception {
        Object raw = lpa.getClass().getMethod("getProfiles").invoke(lpa);
        List<?> list = (List<?>) raw;
        ArrayList<Profile> profiles = new ArrayList<>();
        for (Object item : list) {
            profiles.add(Profile.from(item));
        }
        return profiles;
    }

    private void switchTarget(String target, boolean byIccid, String exactProvider) throws Exception {
        LpaSession session = openWorkingLpa();
        ArrayList<Profile> matches = new ArrayList<>();
        String needle = target.toLowerCase(Locale.ROOT);
        for (Profile profile : session.profiles) {
            if (byIccid) {
                if (profile.iccid.equals(target)) {
                    matches.add(profile);
                }
            } else if (exactProvider != null) {
                if (profile.displayName().equals(target) &&
                    (exactProvider.isEmpty() || profile.provider.equals(exactProvider))) {
                    matches.add(profile);
                }
            } else if (profile.iccid.equals(target) ||
                profile.displayName().equalsIgnoreCase(target) ||
                profile.name.equalsIgnoreCase(target) ||
                profile.nickName.equalsIgnoreCase(target) ||
                profile.provider.equalsIgnoreCase(target) ||
                profile.displayName().toLowerCase(Locale.ROOT).contains(needle) ||
                profile.provider.toLowerCase(Locale.ROOT).contains(needle)) {
                matches.add(profile);
            }
        }

        JSONObject out = new JSONObject();
        if (matches.isEmpty()) {
            out.put("ok", false).put("error", "profile not found").put("target", target);
            System.out.println(out.toString());
            System.exit(2);
        }
        if (matches.size() > 1) {
            out.put("ok", false)
                .put("error", "ambiguous profile")
                .put("target", target)
                .put("matches", profilesJson(matches));
            System.out.println(out.toString());
            System.exit(3);
        }

        Profile profile = matches.get(0);
        if ("Enabled".equals(profile.state)) {
            out.put("ok", true)
                .put("message", "already-enabled")
                .put("profile", profile.toJson());
            System.out.println(out.toString());
            return;
        }

        boolean ok = (Boolean) session.lpa.getClass()
            .getMethod("enableProfile", String.class, boolean.class)
            .invoke(session.lpa, profile.iccid, true);
        if (!ok) {
            ok = (Boolean) session.lpa.getClass()
                .getMethod("enableProfile", String.class, boolean.class)
                .invoke(session.lpa, profile.iccid, false);
        }

        out.put("ok", ok)
            .put("message", ok ? "switched" : "switch failed")
            .put("profile", profile.toJson());
        System.out.println(out.toString());
        if (!ok) {
            System.exit(4);
        }
    }

    private static void printActivationParse(String raw, boolean dryRun) throws Exception {
        ActivationCode activation = ActivationCode.parse(raw);
        JSONObject out = activation.toJson();
        out.put("ok", true);
        if (dryRun) {
            out.put("dryRun", true);
        }
        System.out.println(out.toString());
    }

    private void downloadProfile(String rawActivation, String confirmationCode) throws Exception {
        ActivationCode activation = ActivationCode.parse(rawActivation);
        if (activation.confirmationCodeRequired && isBlank(confirmationCode)) {
            JSONObject out = new JSONObject()
                .put("ok", false)
                .put("error", "confirmation code required")
                .put("smdpAddress", activation.smdpAddress);
            System.out.println(out.toString());
            System.exit(5);
        }

        LpaSession session = openWorkingLpa();
        Set<String> before = new HashSet<>();
        for (Profile profile : session.profiles) {
            before.add(profile.iccid);
        }

        Class<?> inputClass = appClassLoader.loadClass("net.typeblog.lpac_jni.ProfileDownloadInput");
        Class<?> callbackClass = appClassLoader.loadClass("net.typeblog.lpac_jni.ProfileDownloadCallback");
        Object input = inputClass
            .getConstructor(String.class, String.class, String.class, String.class)
            .newInstance(
                activation.smdpAddress,
                emptyToNull(activation.matchingId),
                emptyToNull(imei),
                emptyToNull(confirmationCode)
            );

        DownloadCallback callbackHandler = new DownloadCallback();
        Object callback = Proxy.newProxyInstance(
            appClassLoader,
            new Class<?>[] { callbackClass },
            callbackHandler
        );

        try {
            session.lpa.getClass()
                .getMethod("downloadProfile", inputClass, callbackClass)
                .invoke(session.lpa, input, callback);
        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            printDownloadFailure(cause == null ? e : cause, callbackHandler);
            System.exit(6);
            if (cause instanceof Exception) {
                throw (Exception) cause;
            }
            if (cause instanceof Error) {
                throw (Error) cause;
            }
            throw e;
        }

        List<Profile> afterProfiles = readProfiles(session.lpa);
        JSONArray addedProfiles = new JSONArray();
        for (Profile profile : afterProfiles) {
            if (!before.contains(profile.iccid)) {
                addedProfiles.put(profile.toJson());
            }
        }

        JSONObject out = new JSONObject()
            .put("ok", true)
            .put("message", "downloaded")
            .put("smdpAddress", activation.smdpAddress)
            .put("states", callbackHandler.states)
            .put("addedProfiles", addedProfiles);
        if (callbackHandler.remoteProfile.length() > 0) {
            out.put("remoteProfile", callbackHandler.remoteProfile);
        }
        System.out.println(out.toString());
    }

    private void printDownloadFailure(Throwable cause, DownloadCallback callbackHandler) throws Exception {
        JSONObject out = new JSONObject()
            .put("ok", false)
            .put("error", cause.getClass().getSimpleName())
            .put("message", String.valueOf(cause.getMessage()))
            .put("states", callbackHandler.states);
        if (currentHttpHandler != null) {
            out.put("http", currentHttpHandler.toJson());
        }
        System.out.println(out.toString());
    }

    private static void printProfilesText(List<Profile> profiles) {
        for (Profile p : profiles) {
            System.out.println("PROFILE name=\"" + quoteText(p.displayName()) +
                "\" state=\"" + ("Enabled".equals(p.state) ? "已启用" : "已禁用") +
                "\" provider=\"" + quoteText(p.provider) +
                "\" iccid=\"" + quoteText(p.iccid) +
                "\" class=\"" + quoteText(p.profileClass) +
                "\"");
        }
    }

    private static JSONArray profilesJson(List<Profile> profiles) throws Exception {
        JSONArray arr = new JSONArray();
        for (Profile p : profiles) {
            arr.put(p.toJson());
        }
        return arr;
    }

    private static String invokeString(Object target, String method) throws Exception {
        Object value = target.getClass().getMethod(method).invoke(target);
        return value == null ? "" : String.valueOf(value);
    }

    private static String quoteText(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private static String emptyToNull(String value) {
        return isBlank(value) ? null : value;
    }

    private static byte[] hex(String s) {
        int len = s.length();
        byte[] out = new byte[len / 2];
        for (int i = 0; i < len; i += 2) {
            out[i / 2] = (byte) Integer.parseInt(s.substring(i, i + 2), 16);
        }
        return out;
    }

    private static String encodeHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format(Locale.ROOT, "%02X", b & 0xff));
        }
        return sb.toString();
    }

    private static final class LpaSession {
        final Object lpa;
        final List<Profile> profiles;
        final String eid;

        LpaSession(Object lpa, List<Profile> profiles, String eid) {
            this.lpa = lpa;
            this.profiles = profiles;
            this.eid = eid;
        }
    }

    private static final class Profile {
        final String iccid;
        final String state;
        final String name;
        final String nickName;
        final String provider;
        final String isdpAid;
        final String profileClass;

        private Profile(String iccid, String state, String name, String nickName, String provider, String isdpAid, String profileClass) {
            this.iccid = iccid;
            this.state = state;
            this.name = name;
            this.nickName = nickName;
            this.provider = provider;
            this.isdpAid = isdpAid;
            this.profileClass = profileClass;
        }

        static Profile from(Object item) throws Exception {
            return new Profile(
                getter(item, "getIccid"),
                getter(item, "getState"),
                getter(item, "getName"),
                getter(item, "getNickName"),
                getter(item, "getProviderName"),
                getter(item, "getIsdpAID"),
                getter(item, "getProfileClass")
            );
        }

        String displayName() {
            return nickName.isEmpty() ? name : nickName;
        }

        JSONObject toJson() throws Exception {
            return new JSONObject()
                .put("iccid", iccid)
                .put("state", state)
                .put("name", name)
                .put("nickName", nickName)
                .put("displayName", displayName())
                .put("provider", provider)
                .put("isdpAid", isdpAid)
                .put("class", profileClass);
        }

        private static String getter(Object item, String name) throws Exception {
            Object value = item.getClass().getMethod(name).invoke(item);
            return value == null ? "" : String.valueOf(value);
        }
    }

    private static final class ActivationCode {
        final String activationCode;
        final String smdpAddress;
        final String matchingId;
        final String oid;
        final boolean confirmationCodeRequired;

        private ActivationCode(String activationCode, String smdpAddress, String matchingId, String oid, boolean confirmationCodeRequired) {
            this.activationCode = activationCode;
            this.smdpAddress = smdpAddress;
            this.matchingId = matchingId;
            this.oid = oid;
            this.confirmationCodeRequired = confirmationCodeRequired;
        }

        static ActivationCode parse(String raw) throws Exception {
            String decoded = URLDecoder.decode(raw == null ? "" : raw.trim(), "UTF-8").trim();
            String lower = decoded.toLowerCase(Locale.ROOT);
            int start = lower.indexOf("lpa:1$");
            String lpa = start >= 0 ? decoded.substring(start) : decoded;
            lpa = cutAtTerminator(lpa).trim();
            if (lpa.toLowerCase(Locale.ROOT).startsWith("lpa:")) {
                lpa = lpa.substring(4);
            }

            String[] parts = lpa.split("\\$", -1);
            if (parts.length < 2 || !"1".equals(parts[0])) {
                throw new IllegalArgumentException("Invalid AC_Format");
            }
            String smdpAddress = parts[1].trim();
            if (smdpAddress.isEmpty()) {
                throw new IllegalArgumentException("SM-DP+ is required");
            }
            String matchingId = parts.length > 2 ? parts[2].trim() : "";
            String oid = parts.length > 3 ? parts[3].trim() : "";
            boolean confirmationRequired = parts.length > 4 && "1".equals(parts[4].trim());

            ArrayList<String> normalized = new ArrayList<>();
            normalized.add("1");
            normalized.add(smdpAddress);
            normalized.add(matchingId);
            normalized.add(oid);
            if (confirmationRequired) {
                normalized.add("1");
            }
            while (normalized.size() > 1 && normalized.get(normalized.size() - 1).isEmpty()) {
                normalized.remove(normalized.size() - 1);
            }
            return new ActivationCode(
                "LPA:" + join("$", normalized),
                smdpAddress,
                matchingId,
                oid,
                confirmationRequired
            );
        }

        JSONObject toJson() throws Exception {
            return new JSONObject()
                .put("activationCode", activationCode)
                .put("smdpAddress", smdpAddress)
                .put("matchingId", matchingId.isEmpty() ? JSONObject.NULL : matchingId)
                .put("oid", oid.isEmpty() ? JSONObject.NULL : oid)
                .put("confirmationCodeRequired", confirmationCodeRequired);
        }

        private static String cutAtTerminator(String value) {
            for (int i = 0; i < value.length(); i++) {
                char ch = value.charAt(i);
                if (Character.isWhitespace(ch) || ch == '&' || ch == '"' || ch == '\'' || ch == '<' || ch == '>') {
                    return value.substring(0, i);
                }
            }
            return value;
        }

        private static String join(String sep, List<String> values) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < values.size(); i++) {
                if (i > 0) {
                    sb.append(sep);
                }
                sb.append(values.get(i));
            }
            return sb.toString();
        }
    }

    private static final class DownloadCallback implements InvocationHandler {
        final JSONArray states = new JSONArray();
        final JSONObject remoteProfile = new JSONObject();

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            if ("onStatusUpdate".equals(name)) {
                Object state = args[0];
                String simpleName = state.getClass().getSimpleName();
                states.put(simpleName);
                if ("ConfirmingDownload".equals(simpleName)) {
                    Object metadata = state.getClass().getMethod("getMetadata").invoke(state);
                    if (metadata != null) {
                        putGetter(remoteProfile, metadata, "iccid", "getIccid");
                        putGetter(remoteProfile, metadata, "name", "getName");
                        putGetter(remoteProfile, metadata, "provider", "getProviderName");
                        putGetter(remoteProfile, metadata, "class", "getProfileClass");
                    }
                }
                return true;
            }
            if ("toString".equals(name)) {
                return "DownloadCallback";
            }
            throw new UnsupportedOperationException("unsupported download callback method: " + method);
        }

        private static void putGetter(JSONObject out, Object target, String jsonKey, String methodName) throws Exception {
            Object value = target.getClass().getMethod(methodName).invoke(target);
            out.put(jsonKey, value == null ? JSONObject.NULL : String.valueOf(value));
        }
    }

    private static final class OmapiHandler implements InvocationHandler {
        private final Object service;
        private final String readerName;
        private final Map<Integer, Object> channels = new LinkedHashMap<>();
        private Object session;
        private Object listener;
        private int nextHandle = 1;

        OmapiHandler(Object service, String readerName) {
            this.service = service;
            this.readerName = readerName;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            if ("connect".equals(name)) {
                connect();
                return null;
            }
            if ("disconnect".equals(name)) {
                disconnectQuietly();
                return null;
            }
            if ("getValid".equals(name)) {
                return session != null && !isSessionClosed();
            }
            if ("logicalChannelOpen".equals(name)) {
                return logicalChannelOpen((byte[]) args[0]);
            }
            if ("logicalChannelClose".equals(name)) {
                logicalChannelClose((Integer) args[0]);
                return null;
            }
            if ("transmit".equals(name)) {
                return transmit((Integer) args[0], (byte[]) args[1]);
            }
            if ("withLogicalChannel".equals(name)) {
                return withLogicalChannel((byte[]) args[0], args[1]);
            }
            if ("toString".equals(name)) {
                return "OmapiHandler(" + readerName + ")";
            }
            throw new UnsupportedOperationException("unsupported APDU method: " + method);
        }

        private void connect() throws Exception {
            Object reader = service.getClass().getMethod("getReader", String.class).invoke(service, readerName);
            if (reader == null) {
                throw new IllegalStateException("reader not found: " + readerName);
            }
            session = reader.getClass().getMethod("openSession").invoke(reader);
        }

        private int logicalChannelOpen(byte[] aid) throws Exception {
            if (session == null || isSessionClosed()) {
                connect();
            }
            Class<?> listenerClass = Class.forName("android.se.omapi.ISecureElementListener");
            if (listener == null) {
                final Binder binder = new Binder();
                listener = Proxy.newProxyInstance(
                    listenerClass.getClassLoader(),
                    new Class<?>[] { listenerClass },
                    new InvocationHandler() {
                        @Override
                        public Object invoke(Object proxy, Method method, Object[] args) {
                            if ("asBinder".equals(method.getName())) {
                                return binder;
                            }
                            if ("toString".equals(method.getName())) {
                                return "SecureElementListener";
                            }
                            return null;
                        }
                    }
                );
            }
            Object channel = session.getClass()
                .getMethod("openLogicalChannel", byte[].class, byte.class, listenerClass)
                .invoke(session, aid, (byte) 0, listener);
            if (channel == null) {
                throw new IllegalStateException("failed to open logical channel: " + encodeHex(aid));
            }
            int handle = nextHandle++;
            channels.put(handle, channel);
            return handle;
        }

        private boolean isSessionClosed() throws Exception {
            return (Boolean) session.getClass().getMethod("isClosed").invoke(session);
        }

        private void logicalChannelClose(int handle) throws Exception {
            Object channel = channels.remove(handle);
            if (channel != null) {
                boolean closed = (Boolean) channel.getClass().getMethod("isClosed").invoke(channel);
                if (!closed) {
                    channel.getClass().getMethod("close").invoke(channel);
                }
            }
        }

        private byte[] transmit(int handle, byte[] tx) throws Exception {
            Object channel = channels.get(handle);
            if (channel == null) {
                throw new IllegalStateException("invalid logical channel: " + handle);
            }
            for (int i = 0; i < 11; i++) {
                byte[] rx = (byte[]) channel.getClass().getMethod("transmit", byte[].class).invoke(channel, tx);
                if (rx.length != 2 || rx[0] != 0x66 || rx[1] != 0x01) {
                    return rx;
                }
            }
            throw new IllegalStateException("APDU retry exhausted after 0x6601 checksum errors");
        }

        private Object withLogicalChannel(byte[] aid, Object function1) throws Exception {
            int handle = logicalChannelOpen(aid);
            try {
                final int channelHandle = handle;
                InvocationHandler txHandler = new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                        if ("invoke".equals(method.getName())) {
                            return transmit(channelHandle, (byte[]) args[0]);
                        }
                        if ("toString".equals(method.getName())) {
                            return "APDU transmit function";
                        }
                        return null;
                    }
                };
                Object txFunction = Proxy.newProxyInstance(
                    function1.getClass().getClassLoader(),
                    new Class<?>[] { function1.getClass().getClassLoader().loadClass("kotlin.jvm.functions.Function1") },
                    txHandler
                );
                return function1.getClass().getMethod("invoke", Object.class).invoke(function1, txFunction);
            } finally {
                logicalChannelClose(handle);
            }
        }

        private void disconnectQuietly() {
            for (Integer handle : new ArrayList<>(channels.keySet())) {
                try {
                    logicalChannelClose(handle);
                } catch (Exception ignored) {
                }
            }
            if (session != null) {
                try {
                    session.getClass().getMethod("close").invoke(session);
                } catch (Exception ignored) {
                }
                session = null;
            }
        }
    }

    private static final class HttpHandler implements InvocationHandler {
        private final ClassLoader appClassLoader;
        private final String packageName;
        private TrustManager[] trustManagers;
        private String caPem = "";
        private static boolean triedLoadCryptoNative;
        private int pkidCount;
        private boolean trustReady;
        private String trustError = "";
        private int transmitCount;
        private String lastHost = "";
        private int lastResponseCode = -1;
        private String lastTransmitError = "";
        private static String cryptoLoadError = "";

        HttpHandler(ClassLoader appClassLoader, String packageName) {
            this.appClassLoader = appClassLoader;
            this.packageName = packageName;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            if ("usePublicKeyIds".equals(name)) {
                usePublicKeyIds((String[]) args[0]);
                return null;
            }
            if ("transmit".equals(name)) {
                return transmit((String) args[0], (byte[]) args[1], (String[]) args[2]);
            }
            if ("toString".equals(name)) {
                return "CliHttpHandler";
            }
            throw new UnsupportedOperationException("unsupported HTTP method: " + method);
        }

        private void usePublicKeyIds(String[] pkids) throws Exception {
            ensureCryptoNativeLoaded();
            pkidCount = pkids == null ? 0 : pkids.length;
            try {
                Class<?> roots = appClassLoader.loadClass("net.typeblog.lpac_jni.impl.RootCertificatesKt");
                Map<?, ?> certs = (Map<?, ?>) roots.getMethod("getKNOWN_CI_CERTS").invoke(null);
                StringBuilder pem = new StringBuilder();
                if (pkids != null) {
                    for (String pkid : pkids) {
                        Object cert = certs.get(pkid);
                        if (cert != null) {
                            pem.append(String.valueOf(cert)).append('\n');
                        }
                    }
                }
                Object defaultCert = certs.get("81370f5125d0b1d408d4c3b232e6d25e795bebfb");
                if (defaultCert != null && pem.indexOf("81370f5125d0b1d408d4c3b232e6d25e795bebfb") < 0) {
                    pem.append(String.valueOf(defaultCert)).append('\n');
                }
                caPem = pem.toString();
                trustReady = !caPem.isEmpty();
                trustError = "";
            } catch (Throwable ignored) {
                trustManagers = null;
                trustReady = false;
                trustError = throwableSummary(ignored);
            }
        }

        private Object transmit(String urlText, byte[] tx, String[] headers) throws Exception {
            try {
                URL url = new URL(urlText);
                transmitCount++;
                lastHost = url.getHost();
                if (!"https".equals(url.getProtocol())) {
                    throw new IllegalArgumentException("SM-DP+ servers must use the HTTPS protocol");
                }
                CurlResponse curlResponse = curlPost(urlText, tx, headers, urlText.contains("handleNotification") ? 10 : 180);
                lastResponseCode = curlResponse.responseCode;

                Class<?> response = appClassLoader.loadClass("net.typeblog.lpac_jni.HttpInterface$HttpResponse");
                return response.getConstructor(int.class, byte[].class).newInstance(curlResponse.responseCode, curlResponse.body);
            } catch (Throwable t) {
                lastTransmitError = throwableSummary(t);
                if (t instanceof Exception) {
                    throw (Exception) t;
                }
                if (t instanceof Error) {
                    throw (Error) t;
                }
                throw new RuntimeException(t);
            }
        }

        private CurlResponse curlPost(String urlText, byte[] tx, String[] headers, int timeoutSeconds) throws Exception {
            String helperDir = System.getenv("EUICC_HTTP_HELPER_DIR");
            if (helperDir != null && !helperDir.trim().isEmpty()) {
                return helperCurlPost(helperDir, urlText, tx, headers, timeoutSeconds);
            }
            return localCurlPost(urlText, tx, headers, timeoutSeconds);
        }

        private CurlResponse localCurlPost(String urlText, byte[] tx, String[] headers, int timeoutSeconds) throws Exception {
            File dir = new File("/data/data/" + packageName + "/cache");
            if (!dir.isDirectory() && !dir.mkdirs()) {
                dir = new File("/data/local/tmp");
            }
            File req = File.createTempFile("euicc-http-", ".bin", dir);
            File resp = File.createTempFile("euicc-http-", ".out", dir);
            File ca = caPem.isEmpty() ? null : File.createTempFile("euicc-http-", ".pem", dir);
            try {
                writeBytes(req, tx);
                if (ca != null) {
                    writeText(ca, caPem);
                }

                ArrayList<String> cmd = new ArrayList<>();
                cmd.add("/system/bin/curl");
                cmd.add("-sS");
                cmd.add("--request");
                cmd.add("POST");
                cmd.add("--connect-timeout");
                cmd.add(String.valueOf(Math.min(timeoutSeconds, 20)));
                cmd.add("--max-time");
                cmd.add(String.valueOf(timeoutSeconds));
                cmd.add("--output");
                cmd.add(resp.getAbsolutePath());
                cmd.add("--write-out");
                cmd.add("%{http_code}");
                String proxySpec = System.getenv("EUICC_HTTP_PROXY");
                if (proxySpec != null && !proxySpec.trim().isEmpty()) {
                    cmd.add("--proxy");
                    cmd.add(proxySpec);
                }
                if (ca != null) {
                    cmd.add("--cacert");
                    cmd.add(ca.getAbsolutePath());
                }
                for (String header : headers) {
                    if (header != null && !header.trim().isEmpty()) {
                        cmd.add("--header");
                        cmd.add(header);
                    }
                }
                cmd.add("--data-binary");
                cmd.add("@" + req.getAbsolutePath());
                cmd.add(urlText);

                Process process = new ProcessBuilder(cmd).start();
                byte[] stdout = readAll(process.getInputStream());
                byte[] stderr = readAll(process.getErrorStream());
                int rc = process.waitFor();
                String stdoutText = new String(stdout, StandardCharsets.UTF_8).trim();
                String stderrText = new String(stderr, StandardCharsets.UTF_8).trim();
                if (rc != 0) {
                    throw new IllegalStateException("curl exit " + rc + (stderrText.isEmpty() ? "" : ": " + stderrText));
                }
                int code = Integer.parseInt(stdoutText.substring(Math.max(0, stdoutText.length() - 3)));
                return new CurlResponse(code, readFile(resp));
            } finally {
                req.delete();
                resp.delete();
                if (ca != null) {
                    ca.delete();
                }
            }
        }

        private CurlResponse helperCurlPost(String helperDir, String urlText, byte[] tx, String[] headers, int timeoutSeconds) throws Exception {
            File dir = new File(helperDir);
            String id = "req-" + System.currentTimeMillis() + "-" + transmitCount;
            File req = new File(dir, id + ".req");
            File resp = new File(dir, id + ".resp");
            File curl = new File(dir, id + ".curl");
            File code = new File(dir, id + ".code");
            File err = new File(dir, id + ".err");
            File done = new File(dir, id + ".done");
            File ready = new File(dir, id + ".ready");
            File ca = caPem.isEmpty() ? null : new File(dir, id + ".pem");
            try {
                writeBytes(req, tx);
                if (ca != null) {
                    writeText(ca, caPem);
                }
                writeText(curl, curlConfig(urlText, req, resp, ca, headers, timeoutSeconds));
                if (!ready.createNewFile()) {
                    throw new IllegalStateException("failed to create helper ready marker");
                }

                long deadline = System.currentTimeMillis() + (timeoutSeconds + 35L) * 1000L;
                while (System.currentTimeMillis() < deadline) {
                    if (done.exists()) {
                        if (err.exists()) {
                            throw new IllegalStateException(readText(err));
                        }
                        String codeText = readText(code).trim();
                        int httpCode = Integer.parseInt(codeText.substring(Math.max(0, codeText.length() - 3)));
                        return new CurlResponse(httpCode, readFile(resp));
                    }
                    Thread.sleep(200L);
                }
                throw new IllegalStateException("HTTP helper timeout");
            } finally {
                req.delete();
                resp.delete();
                curl.delete();
                code.delete();
                err.delete();
                done.delete();
                ready.delete();
                if (ca != null) {
                    ca.delete();
                }
            }
        }

        private String curlConfig(String urlText, File req, File resp, File ca, String[] headers, int timeoutSeconds) {
            StringBuilder config = new StringBuilder();
            config.append("url = ").append(curlQuote(urlText)).append('\n');
            config.append("silent = true\n");
            config.append("show-error = true\n");
            config.append("request = \"POST\"\n");
            config.append("connect-timeout = ").append(Math.min(timeoutSeconds, 20)).append('\n');
            config.append("max-time = ").append(timeoutSeconds).append('\n');
            config.append("output = ").append(curlQuote(resp.getAbsolutePath())).append('\n');
            config.append("write-out = \"%{http_code}\"\n");
            String proxySpec = System.getenv("EUICC_HTTP_PROXY");
            if (proxySpec != null && !proxySpec.trim().isEmpty()) {
                config.append("proxy = ").append(curlQuote(proxySpec)).append('\n');
            }
            if (ca != null) {
                config.append("cacert = ").append(curlQuote(ca.getAbsolutePath())).append('\n');
            }
            for (String header : headers) {
                if (header != null && !header.trim().isEmpty()) {
                    config.append("header = ").append(curlQuote(header)).append('\n');
                }
            }
            config.append("data-binary = ").append(curlQuote("@" + req.getAbsolutePath())).append('\n');
            return config.toString();
        }

        private static String curlQuote(String value) {
            return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\r", "").replace("\n", "") + "\"";
        }

        private static void writeBytes(File file, byte[] bytes) throws Exception {
            FileOutputStream out = new FileOutputStream(file);
            try {
                out.write(bytes);
            } finally {
                out.close();
            }
        }

        private static void writeText(File file, String text) throws Exception {
            writeBytes(file, text.getBytes(StandardCharsets.UTF_8));
        }

        private static String readText(File file) throws Exception {
            return new String(readFile(file), StandardCharsets.UTF_8);
        }

        private static byte[] readFile(File file) throws Exception {
            InputStream in = new java.io.FileInputStream(file);
            return readAll(in);
        }

        private static final class CurlResponse {
            final int responseCode;
            final byte[] body;

            CurlResponse(int responseCode, byte[] body) {
                this.responseCode = responseCode;
                this.body = body;
            }
        }

        JSONObject toJson() throws Exception {
            return new JSONObject()
                .put("pkidCount", pkidCount)
                .put("trustReady", trustReady)
                .put("trustError", trustError.isEmpty() ? JSONObject.NULL : trustError)
                .put("cryptoLoadError", cryptoLoadError.isEmpty() ? JSONObject.NULL : cryptoLoadError)
                .put("transmitCount", transmitCount)
                .put("lastHost", lastHost.isEmpty() ? JSONObject.NULL : lastHost)
                .put("lastResponseCode", lastResponseCode)
                .put("lastTransmitError", lastTransmitError.isEmpty() ? JSONObject.NULL : lastTransmitError);
        }

        private static String throwableSummary(Throwable t) {
            StringBuilder sb = new StringBuilder();
            Throwable cur = t;
            int depth = 0;
            while (cur != null && depth < 4) {
                if (sb.length() > 0) {
                    sb.append(" <- ");
                }
                sb.append(cur.getClass().getSimpleName());
                String message = cur.getMessage();
                if (message != null && !message.isEmpty()) {
                    sb.append(": ").append(message);
                }
                cur = cur.getCause();
                depth++;
            }
            return sb.toString();
        }

        private static void ensureCryptoNativeLoaded() {
            if (triedLoadCryptoNative) {
                return;
            }
            triedLoadCryptoNative = true;
            Throwable last = null;
            try {
                System.loadLibrary("javacrypto");
                cryptoLoadError = "";
                return;
            } catch (Throwable ignored) {
                last = ignored;
            }
            try {
                System.load("/system/lib64/libjavacrypto.so");
                cryptoLoadError = "";
                return;
            } catch (Throwable ignored) {
                last = ignored;
            }
            try {
                System.load("/system/lib/libjavacrypto.so");
                cryptoLoadError = "";
                return;
            } catch (Throwable ignored) {
                last = ignored;
            }
            cryptoLoadError = last == null ? "unknown" : throwableSummary(last);
        }

        private URLConnection openConnection(URL url) throws Exception {
            String proxySpec = System.getenv("EUICC_HTTP_PROXY");
            if (proxySpec == null || proxySpec.trim().isEmpty()) {
                return url.openConnection();
            }
            String spec = proxySpec.contains("://") ? proxySpec : "http://" + proxySpec;
            URI uri = new URI(spec);
            if (!"http".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null) {
                throw new IllegalArgumentException("EUICC_HTTP_PROXY must be an HTTP proxy");
            }
            int port = uri.getPort() > 0 ? uri.getPort() : 80;
            java.net.Proxy proxy = new java.net.Proxy(Type.HTTP, new InetSocketAddress(uri.getHost(), port));
            return url.openConnection(proxy);
        }

        private static byte[] readAll(InputStream in) throws Exception {
            try {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int n;
                while ((n = in.read(buffer)) != -1) {
                    bytes.write(buffer, 0, n);
                }
                return bytes.toByteArray();
            } finally {
                in.close();
            }
        }
    }
}
