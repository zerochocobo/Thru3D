package org.codelibs.jcifs.smb.impl;

import org.codelibs.jcifs.smb.CIFSException;
import org.codelibs.jcifs.smb.SmbConstants;
import org.codelibs.jcifs.smb.internal.smb2.create.Smb2CreateRequest;
import org.codelibs.jcifs.smb.internal.smb2.create.Smb2CloseRequest;

/** Small bridge to JCIFS's package-scoped tree API. Never invokes its recursive delete method.
 * FILE_NON_DIRECTORY_FILE remains enforced by the server if the path changes after the UI check.
 * FILE_OPEN cannot create a missing object. Read-only attributes are never cleared. */
public final class SingleMediaDelete {
    private SingleMediaDelete() {}
    public static void delete(SmbFile file) throws CIFSException {
        delete(file, false);
    }
    public static void delete(SmbFile file, boolean directory) throws CIFSException {
        if (file.getLocator().getShare() == null || file.getLocator().getUNCPath().equals("\\"))
            throw new CIFSException("File deletion unavailable for this source");
        try (SmbTreeHandleImpl tree = file.ensureTreeConnected()) {
            if (!tree.isSMB2()) throw new CIFSException("File deletion unavailable for this source");
            String path = file.getLocator().getUNCPath();
            Smb2CreateRequest request = new Smb2CreateRequest(tree.getConfig(), path.substring(1));
            request.setDesiredAccess(SmbConstants.DELETE);
            request.setShareAccess(SmbConstants.FILE_NO_SHARE);
            request.setCreateDisposition(Smb2CreateRequest.FILE_OPEN);
            request.setCreateOptions((directory ? Smb2CreateRequest.FILE_DIRECTORY_FILE : Smb2CreateRequest.FILE_NON_DIRECTORY_FILE) |
                Smb2CreateRequest.FILE_DELETE_ON_CLOSE | Smb2CreateRequest.FILE_OPEN_REPARSE_POINT);
            request.chain(new Smb2CloseRequest(tree.getConfig(), path));
            tree.send(request);
        }
    }
}
