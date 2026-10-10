#include <jni.h>
#include <unistd.h>
#include <cerrno>
#include <string>
#include <fcntl.h>
#include <sys/syscall.h>

static std::string bytes(JNIEnv* env, jbyteArray source) {
    if (!source) return {};
    const jsize length = env->GetArrayLength(source);
    if (length < 0 || length > 4096) return {};
    std::string value(static_cast<size_t>(length), '\0');
    if (length) env->GetByteArrayRegion(source, 0, length, reinterpret_cast<jbyte*>(&value[0]));
    return value;
}

// Resolve every parent with openat + O_NOFOLLOW. A swapped directory cannot redirect deletion
// into another tree. unlinkat never traverses a link and removes directories only when empty.
extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_removeAt(JNIEnv* env, jobject, jbyteArray root,
                                                            jbyteArray relative, jboolean directory) {
    std::string base = bytes(env, root), child = bytes(env, relative);
    if (env->ExceptionCheck() || base.empty() || base[0] != '/' || base.find('\0') != std::string::npos ||
        child.find('\0') != std::string::npos || (!child.empty() && child[0] == '/')) return EINVAL;
    std::string path = base + (child.empty() ? "" : "/" + child);
    int parent = ::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent < 0) return errno;
    size_t start = 1;
    while (true) {
        size_t end = path.find('/', start);
        std::string part = path.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") { ::close(parent); return EINVAL; }
        if (end == std::string::npos) {
            int result = ::unlinkat(parent, part.c_str(), directory ? AT_REMOVEDIR : 0);
            int error = result == 0 ? 0 : errno;
            ::close(parent); return error;
        }
        int next = ::openat(parent, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int error = errno;
        ::close(parent);
        if (next < 0) return error;
        parent = next; start = end + 1;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_unlink(JNIEnv* env, jobject, jbyteArray path) {
    if (!path) return EINVAL;
    const jsize length = env->GetArrayLength(path);
    if (length <= 0 || length > 4096) return EINVAL;
    std::string value(static_cast<size_t>(length), '\0');
    env->GetByteArrayRegion(path, 0, length, reinterpret_cast<jbyte*>(&value[0]));
    if (env->ExceptionCheck()) return EINVAL;
    if (value.find('\0') != std::string::npos || value[0] != '/') return EINVAL;
    jbyteArray empty = env->NewByteArray(0);
    if (!empty) return ENOMEM;
    int result = Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_removeAt(env, nullptr, path, empty, false);
    env->DeleteLocalRef(empty);
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_renameAt(JNIEnv* env, jobject, jbyteArray parentPath,
                                                            jbyteArray oldName, jbyteArray newName) {
    std::string parent = bytes(env, parentPath), from = bytes(env, oldName), to = bytes(env, newName);
    if (env->ExceptionCheck() || parent.empty() || parent[0] != '/' || from.empty() || to.empty() ||
        from.find_first_of("/\0", 0, 2) != std::string::npos || to.find_first_of("/\0", 0, 2) != std::string::npos ||
        from == "." || from == ".." || to == "." || to == ".." || parent.find('\0') != std::string::npos) return EINVAL;
    int fd = ::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    size_t start = 1;
    while (fd >= 0 && start < parent.size()) {
        size_t end = parent.find('/', start);
        std::string part = parent.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") { ::close(fd); return EINVAL; }
        int next = ::openat(fd, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int error = errno; ::close(fd);
        if (next < 0) return error;
        fd = next;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    if (fd < 0) return errno;
    // Linux RENAME_NOREPLACE=1: never replace a concurrently created destination.
    int result = static_cast<int>(::syscall(SYS_renameat2, fd, from.c_str(), fd, to.c_str(), 1));
    int error = result == 0 ? 0 : errno; ::close(fd); return error;
}
