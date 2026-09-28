#!/usr/bin/env python3
"""Run complete production boundary helpers; this does not compile native NSFileCoordinator/NSMetadataQuery adapters."""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCES = ("CoordinatedAccess.swift", "DirectoryObservationScope.swift", "RootRelativePath.swift", "Errors.swift")
TESTS = ("CoordinatedAccessTests.swift", "DirectoryObservationScopeTests.swift", "RootRelativePathTests.swift")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release", "both"), default="both")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    subprocess.run(["swift", "--version"], check=True)
    with tempfile.TemporaryDirectory(prefix="cloud-file-boundaries-") as temporary:
        package = Path(temporary)
        (package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "CloudFileBoundaries", targets: [
    .target(name: "SwiftCloudDrive"),
    .testTarget(name: "SwiftCloudDriveTests", dependencies: ["SwiftCloudDrive"])
])
''')
        for names, directory in ((SOURCES, "Sources/SwiftCloudDrive"), (TESTS, "Tests/SwiftCloudDriveTests")):
            target = package / directory
            target.mkdir(parents=True)
            for name in names:
                source = root / directory / name
                shutil.copyfile(source, target / name)
                print(f"input {directory}/{name} sha256={hashlib.sha256(source.read_bytes()).hexdigest()}", flush=True)
        configurations = ("debug", "release") if args.configuration == "both" else (args.configuration,)
        for configuration in configurations:
            subprocess.run(["swift", "test", "--package-path", str(package), "--configuration", configuration,
                            "-Xswiftc", "-warnings-as-errors"], check=True, timeout=180)
    print("Boundary helpers passed. Native coordination, monitoring and sandbox/iCloud behavior remain separate gates.")


if __name__ == "__main__":
    main()
