package org.vrpassthroughplayer.urifixture;

import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Test-only real DocumentsProvider under a separate UID. One exact read-only clip. */
public final class FixtureDocumentsProvider extends DocumentsProvider {
    static File clip(Context context) { return new File(context.getFilesDir(), "mp03_frame_identity.mp4"); }
    static void restore(Context context) throws IOException {
        try (InputStream input = context.getAssets().open("mp03_frame_identity.mp4");
             OutputStream output = new java.io.FileOutputStream(clip(context))) {
            byte[] bytes = new byte[65536];
            for (int n; (n = input.read(bytes)) != -1;) output.write(bytes, 0, n);
        }
    }
    @Override public boolean onCreate() { return true; }
    @Override public Cursor queryRoots(String[] projection) {
        String[] columns = projection != null ? projection : new String[]{DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID, DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.COLUMN_MIME_TYPES};
        MatrixCursor result = new MatrixCursor(columns);
        MatrixCursor.RowBuilder row = result.newRow();
        for (String c : columns) row.add(c, c.equals(DocumentsContract.Root.COLUMN_ROOT_ID) ? "test" :
            c.equals(DocumentsContract.Root.COLUMN_DOCUMENT_ID) ? "root" :
            c.equals(DocumentsContract.Root.COLUMN_TITLE) ? "VR Player test clip" :
            c.equals(DocumentsContract.Root.COLUMN_MIME_TYPES) ? "video/mp4" : 0);
        return result;
    }
    @Override public Cursor queryDocument(String documentId, String[] projection) throws FileNotFoundException {
        if (!documentId.equals("clip") && !documentId.equals("root")) throw new FileNotFoundException();
        if (documentId.equals("clip") && !clip(getContext()).isFile()) throw new FileNotFoundException();
        MatrixCursor result = documents(projection);
        addDocument(result, documentId);
        return result;
    }
    @Override public Cursor queryChildDocuments(String parentId, String[] projection, String order) throws FileNotFoundException {
        if (!parentId.equals("root")) throw new FileNotFoundException();
        MatrixCursor result = documents(projection);
        if (clip(getContext()).isFile()) addDocument(result, "clip");
        return result;
    }
    private MatrixCursor documents(String[] projection) {
        return new MatrixCursor(projection != null ? projection : new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_FLAGS});
    }
    private void addDocument(MatrixCursor result, String id) {
        MatrixCursor.RowBuilder row = result.newRow();
        for (String c : result.getColumnNames()) row.add(c, c.equals(DocumentsContract.Document.COLUMN_DOCUMENT_ID) ? id :
            c.equals(DocumentsContract.Document.COLUMN_DISPLAY_NAME) ? (id.equals("root") ? "Test clips" : "测试视频 😀.mp4") :
            c.equals(DocumentsContract.Document.COLUMN_MIME_TYPE) ? (id.equals("root") ? DocumentsContract.Document.MIME_TYPE_DIR : "video/mp4") :
            c.equals(DocumentsContract.Document.COLUMN_SIZE) ? clip(getContext()).length() : 0);
    }
    @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal cancellation) throws FileNotFoundException {
        if (cancellation != null) cancellation.throwIfCanceled();
        if (!id.equals("clip") || !mode.equals("r") || !clip(getContext()).isFile()) throw new FileNotFoundException();
        return ParcelFileDescriptor.open(clip(getContext()), ParcelFileDescriptor.MODE_READ_ONLY);
    }
}
