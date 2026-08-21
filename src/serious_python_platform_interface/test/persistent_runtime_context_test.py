import builtins
import importlib
import os
import sys
import subprocess
import tempfile
import threading
import types
import unittest
from pathlib import Path


def _load_dispatcher_namespace():
    source_path = (
        Path(__file__).resolve().parents[1]
        / "lib"
        / "src"
        / "dart_bridge_ffi.dart"
    )
    source = source_path.read_text(encoding="utf-8")
    marker = "const _persistentRuntimeBootstrap = r'''"
    start = source.index(marker) + len(marker)
    end = source.index("''';", start)
    code = source[start:end].replace("__CONTROL_PORT__", "1")
    code = code.replace("_stop_event.wait()", "pass")

    bridge = types.ModuleType("dart_bridge")
    bridge.set_enqueue_handler_func = lambda *args: None
    bridge.add_session_restart_handler = lambda *args: None
    bridge.send_bytes = lambda *args: None
    previous_bridge = sys.modules.get("dart_bridge")
    sys.modules["dart_bridge"] = bridge
    previous_import = builtins.__import__
    previous_import_module = importlib.import_module
    previous_environment = os.environ
    previous_putenv = os.putenv
    previous_unsetenv = os.unsetenv
    namespace = {}
    try:
        exec(compile(code, str(source_path), "exec"), namespace)
        namespace["_runtime_environment_proxy"] = namespace["os"].environ
        namespace["_runtime_import_module"] = namespace["importlib"].import_module
    finally:
        builtins.__import__ = previous_import
        importlib.import_module = previous_import_module
        os.environ = previous_environment
        os.putenv = previous_putenv
        os.unsetenv = previous_unsetenv
        if previous_bridge is None:
            sys.modules.pop("dart_bridge", None)
        else:
            sys.modules["dart_bridge"] = previous_bridge
    return namespace


class PersistentRuntimeContextTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.namespace = _load_dispatcher_namespace()

    def setUp(self):
        self._previous_environment = os.environ
        os.environ = self.namespace["_runtime_environment_proxy"]

    def tearDown(self):
        os.environ = self._previous_environment
        self.namespace["_runtime_contexts"].clear()

    def _context(self, root, plugin):
        return self.namespace["_RuntimeContext"](
            {
                "modulePaths": [str(root / plugin)],
                "environmentVariables": {"PYRITE_TEST_PLUGIN": plugin},
            }
        )

    def test_same_package_name_isolated_across_contexts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for plugin in ("one", "two"):
                package = root / plugin / "shared_package"
                package.mkdir(parents=True)
                (package / "__init__.py").write_text(
                    "from .version import VALUE\n", encoding="utf-8"
                )
                (package / "version.py").write_text(
                    f"VALUE = {plugin!r}\n", encoding="utf-8"
                )

            import_module = self.namespace["_runtime_import"]
            first = self._context(root, "one")
            second = self._context(root, "two")
            first_value = first.run(
                lambda: import_module(
                    "shared_package", {}, {}, ("VALUE",), 0
                ).VALUE
            )
            second_value = second.run(
                lambda: self.namespace["_runtime_import_module"](
                    "shared_package"
                ).VALUE
            )

            self.assertEqual(first_value, "one")
            self.assertEqual(second_value, "two")
            self.assertNotIn("shared_package", sys.modules)
            self.assertNotIn("shared_package.version", sys.modules)

    def test_previous_plugin_paths_are_not_a_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_root = root / "one"
            second_root = root / "two"
            first_root.mkdir()
            second_root.mkdir()
            (first_root / "only_first.py").write_text(
                "VALUE = 'first'\n", encoding="utf-8"
            )

            first = self._context(root, "one")
            first.run(lambda: self.namespace["_runtime_import"](
                "only_first", {}, {}, (), 0
            ))
            second = self.namespace["_RuntimeContext"](
                {
                    "modulePaths": [str(second_root)],
                    "environmentVariables": {},
                }
            )
            with self.assertRaises(ModuleNotFoundError):
                second.run(lambda: self.namespace["_runtime_import"](
                    "only_first", {}, {}, (), 0
                ))

    def test_environment_and_path_are_restored(self):
        original_path = list(sys.path)
        original_environment = dict(os.environ)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context = self._context(root, "one")

            def run():
                self.assertEqual(os.environ["PYRITE_TEST_PLUGIN"], "one")
                os.environ["PYRITE_TEST_ONLY"] = "1"
                os.putenv("PYRITE_PUTENV_ONLY", "1")
                self.assertEqual(sys.path[0], str(root / "one"))

            context.run(run)

        self.assertEqual(list(sys.path), original_path)
        self.assertEqual(dict(os.environ), original_environment)

    def test_direct_path_mutations_are_context_local(self):
        original_path = list(sys.path)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context = self._context(root, "one")
            injected = str(root / "injected")

            def run():
                sys.path.insert(0, injected)
                self.assertEqual(sys.path[0], injected)
                sys.path.append(str(root / "tail"))
                self.assertIn(str(root / "tail"), sys.path)

            context.run(run)

        self.assertEqual(list(sys.path), original_path)

    def test_child_thread_inherits_context_environment_and_path(self):
        values = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context = self._context(root, "one")
            injected = str(root / "thread-path")

            def run():
                sys.path.insert(0, injected)

                def worker():
                    values.append((os.environ["PYRITE_TEST_PLUGIN"], sys.path[0]))

                thread = threading.Thread(target=worker)
                thread.start()
                thread.join()

            context.run(run)

        self.assertEqual(values, [("one", injected)])

    def test_subprocess_inherits_current_context_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            context = self._context(Path(temporary), "one")
            output = []

            def run():
                result = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        "import os; print(os.environ.get('PYRITE_TEST_PLUGIN'))",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                output.append(result.stdout.strip())

            context.run(run)

        self.assertEqual(output, ["one"])

    def test_subprocess_positional_environment_slot_is_isolated(self):
        with tempfile.TemporaryDirectory() as temporary:
            context = self._context(Path(temporary), "one")
            output = []

            def run():
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        "import os; print(os.environ.get('PYRITE_TEST_PLUGIN'))",
                    ],
                    -1,
                    None,
                    subprocess.PIPE,
                    subprocess.PIPE,
                    None,
                    None,
                    True,
                    False,
                    None,
                    None,
                )
                stdout, _ = process.communicate()
                output.append(stdout.decode().strip())

            context.run(run)

        self.assertEqual(output, ["one"])

    def test_concurrent_imports_keep_their_context(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for plugin in ("one", "two"):
                plugin_root = root / plugin
                plugin_root.mkdir()
                (plugin_root / "concurrent_module.py").write_text(
                    f"VALUE = {plugin!r}\n", encoding="utf-8"
                )

            contexts = [self._context(root, plugin) for plugin in ("one", "two")]
            first_imported = threading.Event()
            release_first = threading.Event()
            values = []

            def worker(context, plugin):
                def run():
                    module = self.namespace["_runtime_import"](
                        "concurrent_module", {}, {}, (), 0
                    )
                    values.append(module.VALUE)
                    if plugin == "one":
                        first_imported.set()
                        release_first.wait()
                        values.append(
                            self.namespace["_runtime_import"](
                                "concurrent_module", {}, {}, (), 0
                            ).VALUE
                        )
                    else:
                        first_imported.wait()
                        release_first.set()

                context.run(run)

            threads = [
                threading.Thread(
                    target=worker, args=(context, plugin)
                )
                for context, plugin in zip(contexts, ("one", "two"))
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()

            self.assertEqual(sorted(values), ["one", "one", "two"])
            self.assertNotIn("concurrent_module", sys.modules)

    def test_native_extension_package_remains_process_visible(self):
        package_name = "persistent_runtime_native_fixture_core"
        wrapper_name = "persistent_runtime_native_fixture_wrapper"
        consumer_name = "persistent_runtime_native_fixture_consumer"
        module_names = (
            package_name,
            f"{package_name}._native",
            wrapper_name,
        )
        shared_modules = self.namespace["_runtime_shared_modules"]
        shared_packages = self.namespace["_runtime_shared_package_names"]
        metadata = self.namespace["importlib"].metadata
        previous_packages_distributions = metadata.packages_distributions
        previous_distribution = metadata.distribution

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plugin_root = root / "plugin"
            package_root = plugin_root / package_name
            package_root.mkdir(parents=True)
            wrapper_root = plugin_root / wrapper_name
            wrapper_root.mkdir()
            context = self._context(root, "plugin")

            package = types.ModuleType(package_name)
            package.__file__ = str(package_root / "__init__.py")
            package.__path__ = [str(package_root)]
            package.token = object()

            native = types.ModuleType(module_names[1])
            extension_suffix = importlib.machinery.EXTENSION_SUFFIXES[0]
            native.__file__ = str(package_root / ("_native" + extension_suffix))

            native_type = type("NativeType", (), {})
            native_type.__module__ = native.__name__
            native.NativeType = native_type

            wrapper = types.ModuleType(module_names[2])
            wrapper.__file__ = str(wrapper_root / "__init__.py")
            wrapper.__path__ = [str(wrapper_root)]
            wrapper.NativeType = native_type

            consumer = types.ModuleType(consumer_name)
            consumer.__file__ = str(plugin_root / (consumer_name + ".py"))
            consumer.NativeType = native_type

            metadata.packages_distributions = lambda: {
                package_name: ["native-fixture-core"],
                wrapper_name: ["native-fixture-wrapper"],
                consumer_name: ["native-fixture-consumer"],
            }
            metadata.distribution = lambda name: types.SimpleNamespace(
                requires={
                    "native-fixture-wrapper": ["native-fixture-core>=1"],
                    "native-fixture-consumer": ["native-fixture-wrapper>=1"],
                }.get(name, [])
            )

            def load_native_package():
                sys.modules[module_names[0]] = package
                sys.modules[module_names[1]] = native
                sys.modules[module_names[2]] = wrapper
                sys.modules[consumer_name] = consumer
                return lambda: sys.modules[package_name].token

            try:
                deferred_lookup = context._with_import(load_native_package)

                self.assertIs(deferred_lookup(), package.token)
                for module_name in module_names:
                    self.assertIs(sys.modules[module_name], shared_modules[module_name])
                    self.assertNotIn(module_name, context.modules)
                self.assertIn(wrapper_name, shared_packages)
                self.assertNotIn(consumer_name, shared_packages)
                self.assertNotIn(consumer_name, sys.modules)
                self.assertIs(context.modules[consumer_name], consumer)

                self.namespace["_reset_command"]({"runtimeEpoch": None})
                self.assertFalse(shared_modules)
                self.assertFalse(shared_packages)
                for module_name in module_names:
                    self.assertNotIn(module_name, sys.modules)
            finally:
                for module_name in module_names:
                    sys.modules.pop(module_name, None)
                    shared_modules.pop(module_name, None)
                sys.modules.pop(consumer_name, None)
                shared_packages.discard(package_name)
                shared_packages.discard(wrapper_name)
                metadata.packages_distributions = (
                    previous_packages_distributions
                )
                metadata.distribution = previous_distribution


if __name__ == "__main__":
    unittest.main()
