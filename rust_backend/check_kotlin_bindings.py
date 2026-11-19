"""Generate and compile Kotlin bindings from a matching *host* cdylib.

Run before the Android cross build, using a host build of mornye-mobile with the
same feature set and the matching UniFFI bindgen. This checks JVM compilation;
it does not test Android, JNI loading, or runtime compatibility.

All inputs are explicit. The output directory must be empty and is left for
inspection. No network or automatic dependency installation is performed.
"""

import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("library", "bindgen", "kotlin-lib-dir", "jna-jar", "output-dir"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    for name in ("library", "bindgen", "jna_jar"):
        if not getattr(args, name).is_file():
            parser.error(f"{name} must be an existing file")
    if not args.kotlin_lib_dir.is_dir():
        parser.error("kotlin-lib-dir must be an existing directory")
    stdlib = [p for p in args.kotlin_lib_dir.glob("kotlin-stdlib-*.jar")
              if p.name[len("kotlin-stdlib-"):].split(".", 1)[0].isdigit()]
    if len(stdlib) != 1:
        parser.error("expected exactly one versioned kotlin-stdlib jar")
    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        parser.error("output-dir must be empty")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    generated = args.output_dir / "generated"
    classes = args.output_dir / "classes"
    generated.mkdir()
    classes.mkdir()
    subprocess.run([str(args.bindgen), "generate", "--library", str(args.library),
                    "--language", "kotlin", "--no-format", "--out-dir", str(generated)], check=True)
    bindings = list(generated.rglob("*.kt"))
    if len(bindings) != 1:
        raise RuntimeError("expected exactly one generated Kotlin binding file")
    subprocess.run(["java", "-Xmx1024m", "-cp", str(args.kotlin_lib_dir / "*"),
                    "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
                    "-classpath", os.pathsep.join((str(stdlib[0]), str(args.jna_jar))),
                    "-d", str(classes), str(bindings[0])], check=True)
    print("Generated Kotlin compiled successfully.")


if __name__ == "__main__":
    main()
