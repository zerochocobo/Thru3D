"""Make the player's MNN 3.6.1 fork: OpenCL convolutions with a fused HardSwish, and more GEMM 1x1s.

MNN fuses only ReLU/ReLU6 into its OpenCL convolution kernels, so every HardSwish of
RVM's MobileNetV3 backbone is a separate kernel that reads and writes the whole
feature map. tools/models/fuse_rvm_graph.py --fuse-hardswish drops those HardSwish
nodes and renames the producing convolution's output with the marker `__hswish`;
this fork applies x * relu6(x + 3) / 6 inside the convolution when it sees the marker
(image-memory ConvExecution, ConvWinograd and DepthwiseConvExecution, the paths the
player uses). Graphs without the marker are unaffected.

Usage: python patch_mnn_vrpp.py <pristine source-3.6.1> <fork directory>
The fork is recreated from the pristine tree; the OpenCL program map is regenerated.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

MARKER = '__hswish'
KERNELS = ['conv_2d.cl', 'depthwise_conv2d.cl', 'winogradTransformDest2_3_1.cl', 'winogradTransformDest2_5_1.cl']
HELPER = f'''
// VRPP: convolutions whose output name carries "{MARKER}" apply HardSwish in the kernel.
static inline bool vrppHardSwish(const MNN::Op* op) {{
    return op != nullptr && op->name() != nullptr && op->name()->str().find("{MARKER}") != std::string::npos;
}}
'''


def patch_kernel(text):
    """After each RELU6 block add an HSWISH block for the same variables."""
    clamp = re.compile(r'^(\s*)(\w+) = clamp\(\2, \(FLOAT4\)\(?0\)?, \(FLOAT4\)\(?6\)?\);\s*$')
    out, block, count = [], None, 0
    for line in text.splitlines(keepends=True):
        out.append(line)
        stripped = line.strip()
        if stripped == '#ifdef RELU6':
            block = []
        elif block is not None and stripped == '#endif':
            if block:
                out.append('#ifdef HSWISH\n')
                for indent, name in block:
                    out.append(f'{indent}{name} = {name} * clamp({name} + (FLOAT4)3, (FLOAT4)0, (FLOAT4)6) * (FLOAT4)0.16666667f;\n')
                out.append('#endif\n')
                count += 1
            block = None
        elif block is not None:
            m = clamp.match(line)
            if m:
                block.append((m.group(1), m.group(2)))
    return ''.join(out), count


def replace_once(path, old, new):
    text = path.read_text(encoding='utf-8')
    assert text.count(old) == 1, (path.name, old[:60], text.count(old))
    path.write_text(text.replace(old, new), encoding='utf-8', newline='\n')


def main():
    pristine, fork = Path(sys.argv[1]), Path(sys.argv[2])
    if fork.exists():
        shutil.rmtree(fork)
    shutil.copytree(pristine, fork, ignore=shutil.ignore_patterns('.git'))
    cl = fork / 'source/backend/opencl/execution/cl'
    for name in KERNELS:
        path = cl / name
        text, count = patch_kernel(path.read_text(encoding='utf-8'))
        assert count > 0, name
        path.write_text(text, encoding='utf-8', newline='\n')
        print(f'{name}: {count} HSWISH blocks')
    image = fork / 'source/backend/opencl/execution/image'
    replace_once(image / 'ConvExecution.cpp', '''    } else if (mResource->mRelu6) {
        mResource->mBuildOptions.emplace("-DRELU6");
    }else if(mResource->mPrelu){''', '''    } else if (mResource->mRelu6) {
        mResource->mBuildOptions.emplace("-DRELU6");
    } else if (vrppHardSwish(op)) {
        mResource->mBuildOptions.emplace("-DHSWISH");
    }else if(mResource->mPrelu){''')
    replace_once(image / 'ConvWinograd.cpp', '''            if (mResource->mCommon->relu6()) {
                buildOptions.emplace("-DRELU6");
            }''', '''            if (mResource->mCommon->relu6()) {
                buildOptions.emplace("-DRELU6");
            }
            if (vrppHardSwish(mOp)) {
                buildOptions.emplace("-DHSWISH");
            }''')
    replace_once(image / 'DepthwiseConvExecution.cpp', '''    } else if (mResource->mConv2dCommonParams->relu6() == true) {
        mResource->mBuildOptions.emplace("-DRELU6");
    }
}''', '''    } else if (mResource->mConv2dCommonParams->relu6() == true) {
        mResource->mBuildOptions.emplace("-DRELU6");
    } else if (vrppHardSwish(op)) {
        mResource->mBuildOptions.emplace("-DHSWISH");
    }
}''')
    # 2D->3D depth (buffer memory): ViT-S linears at 181 tokens fall under MNN's "total computation"
    # gate (M/512*N/512*K/256 < 1, e.g. the 384x384 attention projection) and run as a plain 1x1
    # convolution at ~0.15 TFLOPS. Sending every eligible 1x1 to the tuned GEMM made the whole
    # model 8.3% faster on Quest 3 (six paired runs, 53.1 -> 48.5 ms); without any GEMM it is 2x slower.
    replace_once(fork / 'source/backend/opencl/execution/buffer/ConvBufExecution.cpp',
        '''       if(M < 128 || 1.0 * M / 512 * N / 512 * K / 256 < 1.0) {''',
        '''       if(M < 128) { // VRPP: no computation gate (small ViT linears are faster as GEMM)''')
    # GPU priority of RVM against the app's rendering, the decoder and the compositor. MNN asks
    # Adreno for LOW, which left RVM waiting behind everything: in 8K playback a plain frame took
    # 32.25 ms at LOW and 28.75 ms at NORMAL (HIGH no better), with Godot still at 72 fps. The fork
    # defaults to NORMAL; debug.vrpp.cl.priority = low | high overrides it (read when the process
    # creates its OpenCL context).
    runtime = fork / 'source/backend/opencl/core/runtime/OpenCLRuntime.cpp'
    replace_once(runtime, 'namespace MNN {', '''#include <cstring>
#if defined(__ANDROID__)
#include <sys/system_properties.h>
#endif
namespace MNN {
// VRPP: a runtime created on this thread right after vrpp_set_cl_priority(p) uses p (2D->3D depth
// sets LOW so the video's GL copies preempt it; 1080p60 then shows every frame). -1 restores default.
static thread_local int vrppPriorityOverride = -1;
} // namespace MNN
extern "C" void vrpp_set_cl_priority(int priority) { MNN::vrppPriorityOverride = priority; }
namespace MNN {
// VRPP: 0 low (upstream MNN), 1 normal (player default), 2 high; debug.vrpp.cl.priority overrides.
static int vrppPriority() {
    if (vrppPriorityOverride >= 0) return vrppPriorityOverride;
#if defined(__ANDROID__)
    char value[PROP_VALUE_MAX] = {0};
    if (__system_property_get("debug.vrpp.cl.priority", value) > 0) {
        if (strcmp(value, "high") == 0) return 2;
        if (strcmp(value, "low") == 0) return 0;
    }
#endif
    return 1;
}''')
    replace_once(runtime, '''                context_properties.push_back(CL_CONTEXT_PRIORITY_HINT_QCOM);
                context_properties.push_back(CL_PRIORITY_HINT_LOW_QCOM);''', '''                context_properties.push_back(CL_CONTEXT_PRIORITY_HINT_QCOM);
                context_properties.push_back(vrppPriority() == 2 ? CL_PRIORITY_HINT_HIGH_QCOM
                    : vrppPriority() == 1 ? CL_PRIORITY_HINT_NORMAL_QCOM : CL_PRIORITY_HINT_LOW_QCOM);''')
    replace_once(runtime, '''                cl_queue_properties prop[] = {CL_QUEUE_PRIORITY_KHR, CL_QUEUE_PRIORITY_LOW_KHR,''',
        '''                cl_queue_properties prop[] = {CL_QUEUE_PRIORITY_KHR, (cl_queue_properties)(vrppPriority() == 2 ? CL_QUEUE_PRIORITY_HIGH_KHR
                    : vrppPriority() == 1 ? CL_QUEUE_PRIORITY_MED_KHR : CL_QUEUE_PRIORITY_LOW_KHR),''')
    for name in ('ConvExecution.cpp', 'ConvWinograd.cpp', 'DepthwiseConvExecution.cpp'):
        path = image / name
        text = path.read_text(encoding='utf-8')
        anchor = 'namespace MNN {'
        assert anchor in text, name
        path.write_text(text.replace(anchor, anchor + HELPER, 1), encoding='utf-8', newline='\n')
    # The generated program sources are committed in MNN; regenerate them from the patched .cl files,
    # then keep MNN's own generated files for every kernel this fork does not touch.
    subprocess.run([sys.executable, 'opencl_codegen.py', '.'], cwd=cl, check=True)
    patched = {name[:-3] + '_mnn_cl.cpp' for name in KERNELS}
    for generated in (pristine / 'source/backend/opencl/execution/cl').glob('*_mnn_cl.cpp'):
        if generated.name not in patched:
            shutil.copyfile(generated, cl / generated.name)
    print('fork ready:', fork)


if __name__ == '__main__':
    main()
