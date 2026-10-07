package org.vrpassthroughplayer.urifixture;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Process;
import org.json.JSONObject;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.UUID;

/** Shell-only control of this test provider, restricted to one target package/URI. */
public final class FixtureCommandReceiver extends BroadcastReceiver {
    private static final String PROCESS = UUID.randomUUID().toString();
    private static final String TARGET = "com.wapok.thru3d";
    private static final Uri URI = Uri.parse("content://org.vrpassthroughplayer.urifixture.documents/document/clip");
    @Override public void onReceive(Context context, Intent intent) {
        String request = intent.getStringExtra("request");
        if (request == null || !request.matches("[a-zA-Z0-9_-]{1,64}")) return;
        String operation = intent.getStringExtra("operation");
        JSONObject report = new JSONObject();
        try {
            report.put("request",request).put("operation",operation).put("uri",URI.toString())
                .put("provider_process",PROCESS).put("provider_uid",Process.myUid());
            switch (operation == null ? "" : operation) {
                case "restore": FixtureDocumentsProvider.restore(context); break;
                case "remove":
                    if (FixtureDocumentsProvider.clip(context).exists() && !FixtureDocumentsProvider.clip(context).delete()) throw new Exception("Fixture removal failed");
                    break;
                case "grant": context.grantUriPermission(TARGET,URI,Intent.FLAG_GRANT_READ_URI_PERMISSION); break;
                case "offer_persistable": context.grantUriPermission(TARGET,URI,Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION); break;
                case "revoke": context.revokeUriPermission(URI,Intent.FLAG_GRANT_READ_URI_PERMISSION); break;
                default: throw new IllegalArgumentException("Unknown operation");
            }
            report.put("state","applied").put("clip_exists",FixtureDocumentsProvider.clip(context).isFile());
            report.put("client_uid",context.getPackageManager().getApplicationInfo(TARGET,0).uid);
            if (FixtureDocumentsProvider.clip(context).isFile()) {
                byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(FixtureDocumentsProvider.clip(context).toPath()));
                StringBuilder hex = new StringBuilder();
                for (byte b : digest) hex.append(String.format(java.util.Locale.ROOT,"%02x",b & 255));
                report.put("clip_sha256",hex.toString());
            }
        } catch (Exception error) {
            try { report.put("state","failed").put("detail",error.toString()); } catch (Exception ignored) { }
        }
        try {
            File directory = new File(context.getFilesDir(),"diagnostics");
            if (!directory.mkdirs() && !directory.isDirectory()) throw new Exception("No diagnostics directory");
            File temporary = File.createTempFile("uri-control-",".tmp",directory);
            Files.write(temporary.toPath(),report.toString().getBytes(StandardCharsets.UTF_8));
            if (!temporary.renameTo(new File(directory,request+".json"))) throw new Exception("Report rename failed");
        } catch (Exception error) { android.util.Log.e("UriFixture","Report failed",error); }
    }
}
