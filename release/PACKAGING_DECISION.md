# macOS ARM64 packaging decision

Date: 2026-08-13

Use one target-specific Mix release with a private Erlang/OTP runtime. Do not
maintain a Burrito path at this time.

The source release configuration sets `jido_cli` and `llm_db` to load mode.
This resolves the transitive `llm_db` ownership conflict without an edit to a
compiled dependency. The public launcher enters `Jido.Cli.Release.Entry` from
the `start_clean` boot file. It does not contain a release `eval` expression.

The exact local candidate had these results:

- artifact: `jido-0.1.0-darwin-arm64.tar.gz`;
- archive size: 74 MiB;
- extracted release size: 217 MiB;
- 78 reviewed shipped applications;
- five ARM64 Mach-O native libraries;
- help warm median: 218.341 ms;
- version warm median: 222.639 ms;
- first-frame warm median: 227.0 ms;
- runtime-ready warm median: 903.5 ms;
- identical SHA-256 values from two controlled package assemblies.

The final archive passed private-runtime, relocation, read-only installation,
runtime-data, native-load, provider-free replay, terminal cleanup, startup
failure, and queued-input gates. The source tree was dirty, so this local
candidate is correctly marked not publishable.

Reconsider this decision only if a native target cannot meet the same artifact
contract with a source-built Mix release, or if the private runtime cannot meet
a required terminal, native-library, or startup gate. A later target must
confirm this method on its native system. Package size alone is not a reason to
maintain two packaging methods.
