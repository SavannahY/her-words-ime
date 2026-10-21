#!/usr/bin/env python3
"""Generate the checked-in Xcode project without XcodeGen or third-party tools."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def serialize(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(
            indent + "\t" + json.dumps(key) + " = " + serialize(item, depth + 1) + ";\n"
            for key, item in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(indent + "\t" + serialize(item, depth + 1) + ",\n" for item in value) + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


def build_project():
    objects = {}

    def add(key, isa, **fields):
        obj_id = identifier(key)
        objects[obj_id] = {"isa": isa, **fields}
        return obj_id

    def reference(path, file_type):
        return add("file:" + path, "PBXFileReference", lastKnownFileType=file_type,
                   path=path, sourceTree="<group>")

    shared = sorted(path.relative_to(IOS).as_posix() for path in (IOS / "Shared").glob("*.swift"))
    if not shared:
        raise ValueError("Generate the Shared Swift sources first.")
    app_sources = sorted(path.relative_to(IOS).as_posix() for path in (IOS / "App").glob("*.swift")) + shared
    keyboard_sources = ["Keyboard/KeyboardViewController.swift"] + shared
    resources = sorted(path.relative_to(IOS).as_posix() for path in (IOS / "Keyboard/Resources").glob("*") if path.is_file())
    references = {path: reference(path, "sourcecode.swift") for path in sorted(set(app_sources + keyboard_sources))}
    app_resources = [path for path in resources if Path(path).name not in {"lexicon.json", "data-info.json"}] + ["../speech/profiles.json"] + sorted(
        path.relative_to(IOS).as_posix() for path in (IOS / "App/Resources").glob("*") if path.is_file())
    for path in sorted(set(resources + app_resources)):
        references[path] = reference(path, "text.json" if path.endswith(".json") else "text")
    plist_refs = [reference("App/Info.plist", "text.plist.xml"), reference("Keyboard/Info.plist", "text.plist.xml")]
    config_reference = reference("Config.xcconfig", "text.xcconfig")

    app_product = add("product:app", "PBXFileReference", explicitFileType="wrapper.application",
                      includeInIndex=0, path="HerWords.app", sourceTree="BUILT_PRODUCTS_DIR")
    extension_product = add("product:keyboard", "PBXFileReference", explicitFileType="wrapper.app-extension",
                            includeInIndex=0, path="HerWordsKeyboard.appex", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("group:products", "PBXGroup", children=[app_product, extension_product], name="Products", sourceTree="<group>")
    main_group = add("group:root", "PBXGroup", children=list(references.values()) + plist_refs + [config_reference, products], sourceTree="<group>")

    def phase(target, kind, paths):
        files = [add("build:" + target + ":" + path, "PBXBuildFile", fileRef=references[path]) for path in paths]
        return add("phase:" + target + ":" + kind, kind, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

    package_ref = add("package:speech", "XCLocalSwiftPackageReference", relativePath="..")
    package_product = add("packageproduct:speech", "XCSwiftPackageProductDependency", package=package_ref, productName="HerBilingualASR")
    package_build = add("build:speech", "PBXBuildFile", productRef=package_product)
    app_frameworks = add("phase:app:frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                         files=[package_build], runOnlyForDeploymentPostprocessing=0)
    app_phases = [phase("app", "PBXSourcesBuildPhase", app_sources), phase("app", "PBXResourcesBuildPhase", app_resources),
                  app_frameworks]
    keyboard_phases = [phase("keyboard", "PBXSourcesBuildPhase", keyboard_sources), phase("keyboard", "PBXResourcesBuildPhase", resources),
                       phase("keyboard", "PBXFrameworksBuildPhase", [])]
    embedded = add("embed:keyboard", "PBXBuildFile", fileRef=extension_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
    app_phases.append(add("phase:embed", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                          files=[embedded], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0))

    def configurations(name, base):
        configs = []
        for config in ("Debug", "Release"):
            settings = dict(base)
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
                             "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym"})
            if config == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            extra = {"baseConfigurationReference": config_reference} if name == "project" else {}
            configs.append(add("config:" + name + ":" + config, "XCBuildConfiguration", buildSettings=settings, name=config, **extra))
        return add("configlist:" + name, "XCConfigurationList", buildConfigurations=configs,
                   defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    common = {"IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
              "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
    project_configs = configurations("project", common)
    target_common = {"CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1",
                     "MARKETING_VERSION": "0.2.0", "GENERATE_INFOPLIST_FILE": "NO", "TARGETED_DEVICE_FAMILY": "1,2",
                     "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SWIFT_EMIT_LOC_STRINGS": "YES"}
    app_settings = {**target_common, "PRODUCT_BUNDLE_IDENTIFIER": "$(HER_BUNDLE_PREFIX)", "PRODUCT_NAME": "HerWords",
                    "INFOPLIST_FILE": "App/Info.plist", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]}
    keyboard_settings = {**target_common, "PRODUCT_BUNDLE_IDENTIFIER": "$(HER_BUNDLE_PREFIX).keyboard", "PRODUCT_NAME": "HerWordsKeyboard",
                         "INFOPLIST_FILE": "Keyboard/Info.plist", "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
                         "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]}
    keyboard_target = add("target:keyboard", "PBXNativeTarget", buildConfigurationList=configurations("keyboard", keyboard_settings),
                          buildPhases=keyboard_phases, buildRules=[], dependencies=[], name="HerWordsKeyboard",
                          productName="HerWordsKeyboard", productReference=extension_product, productType="com.apple.product-type.app-extension")
    proxy = add("proxy:keyboard", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1,
                remoteGlobalIDString=keyboard_target, remoteInfo="HerWordsKeyboard")
    dependency = add("dependency:keyboard", "PBXTargetDependency", target=keyboard_target, targetProxy=proxy)
    app_target = add("target:app", "PBXNativeTarget", buildConfigurationList=configurations("app", app_settings),
                     buildPhases=app_phases, buildRules=[], dependencies=[dependency], name="HerWords", productName="HerWords",
                     productReference=app_product, productType="com.apple.product-type.application",
                     packageProductDependencies=[package_product])
    project_id = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600",
                     "TargetAttributes": {app_target: {"CreatedOnToolsVersion": "16.0"}, keyboard_target: {"CreatedOnToolsVersion": "16.0"}}},
                     buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
                     hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group,
                     productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, keyboard_target],
                     packageReferences=[package_ref])
    return "// !$*UTF8*$!\n" + serialize({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id}) + "\n"


def build_scheme():
    app = identifier("target:app")
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="HerWords.app" BlueprintName="HerWords" ReferencedContainer="container:HerWords.xcodeproj"/>'
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare checked-in project without writing")
    args = parser.parse_args()
    outputs = {IOS / "HerWords.xcodeproj/project.pbxproj": build_project(),
               IOS / "HerWords.xcodeproj/xcshareddata/xcschemes/HerWords.xcscheme": build_scheme()}
    for path, content in outputs.items():
        if args.check:
            if not path.is_file() or path.read_text() != content:
                print("Project is stale: " + str(path.relative_to(ROOT)), file=sys.stderr)
                return 1
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print("Xcode project " + ("matches sources." if args.check else "generated."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
