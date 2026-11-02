// 职责: 验证 CargoKit 为本地原生构建选择锁定的 Rust 编译器。
// 关联文件:
//   third/fjs/cargokit/build_tool/lib/src/builder.dart
//   third/fjs/libfjs/cargokit.yaml
import 'package:build_tool/src/builder.dart';
import 'package:build_tool/src/cargo.dart';
import 'package:build_tool/src/options.dart';
import 'package:build_tool/src/target.dart';
import 'package:build_tool/src/util.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    testRunCommandOverride = null;
  });

  test('cargo build uses rustc from the selected rustup toolchain', () async {
    Map<String, String>? cargoEnvironment;
    testRunCommandOverride = (args) {
      if (args.executable == 'rustup' &&
          args.arguments.length == 4 &&
          args.arguments[0] == 'which' &&
          args.arguments[1] == '--toolchain' &&
          args.arguments[2] == 'stable' &&
          args.arguments[3] == 'rustc') {
        return TestRunCommandResult(stdout: '/rustup/stable/bin/rustc\n');
      }

      if (args.executable == 'rustup' &&
          args.arguments.length >= 4 &&
          args.arguments[0] == 'run' &&
          args.arguments[1] == 'stable' &&
          args.arguments[2] == 'cargo' &&
          args.arguments[3] == 'build') {
        cargoEnvironment = args.environment;
        return TestRunCommandResult();
      }

      throw StateError(
          'Unexpected command: ${args.executable} ${args.arguments}');
    };

    final builder = RustBuilder(
      target: Target.forRustTriple('x86_64-pc-windows-msvc')!,
      environment: BuildEnvironment(
        configuration: BuildConfiguration.release,
        crateOptions: CargokitCrateOptions(),
        targetTempDir: '/tmp/fjs-cargokit-test',
        manifestDir: '/tmp/fjs-cargokit-manifest',
        crateInfo: CrateInfo(packageName: 'fjs'),
        isAndroid: false,
      ),
    );

    await builder.build();

    expect(cargoEnvironment?['RUSTC'], '/rustup/stable/bin/rustc');
  });

  test('ordinary local builds honor the pinned generation recipe', () async {
    final commands = <List<String>>[];
    testRunCommandOverride = (args) {
      commands.add(args.arguments);
      if (args.arguments.first == 'which') {
        return TestRunCommandResult(stdout: '/rustup/1.99.1/bin/rustc\n');
      }
      expect(args.environment?['RUSTC'], '/rustup/1.99.1/bin/rustc');
      return TestRunCommandResult();
    };
    final options = CargokitCrateOptions.load(manifestDir: '../../libfjs');
    for (final triple in [
      'x86_64-pc-windows-msvc',
      'x86_64-unknown-linux-gnu'
    ]) {
      await RustBuilder(
        target: Target.forRustTriple(triple)!,
        environment: BuildEnvironment(
          configuration: BuildConfiguration.release,
          crateOptions: options,
          targetTempDir: '/tmp/fjs-cargokit-test',
          manifestDir: '../../libfjs',
          crateInfo: CrateInfo(packageName: 'fjs'),
          isAndroid: false,
        ),
      ).build();
    }
    expect(
        commands
            .where((args) => args.first == 'run')
            .every((args) => args[1] == '1.99.1'),
        isTrue);
    expect(
        commands
            .where((args) => args.first == 'which')
            .every((args) => args[2] == '1.99.1'),
        isTrue);
  });
}
