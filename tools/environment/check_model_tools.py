"""Check the Windows ONNX reference environment, not Quest RVM performance."""
import json
import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper

graph = helper.make_graph(
    [helper.make_node("Identity", ["input"], ["output"])],
    "environment_smoke",
    [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 2, 2])],
    [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 2, 2])],
)
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
model.ir_version = 9
onnx.checker.check_model(model)
session = ort.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
input_value = np.arange(12, dtype=np.float32).reshape(1, 3, 2, 2)
output_value = session.run(None, {"input": input_value})[0]
np.testing.assert_array_equal(output_value, input_value)
print(json.dumps({"onnx": onnx.__version__, "onnxruntime": ort.__version__,
                  "numpy": np.__version__, "providers": session.get_providers(),
                  "identity_inference": "passed"}, indent=2))

