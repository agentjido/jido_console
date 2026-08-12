# jido_cli

A small terminal coding harness built on [Jidoka](https://github.com/agentjido/jidoka).
The Mix package is `jido_cli`; the generated executable is `jido`.

This spike has one direct dependency: the public `jidoka` package from Hex.

## Build

Elixir 1.18 or newer is required to build the executable.

```sh
mix deps.get
MIX_ENV=prod mix escript.build
./jido --version
```

`mix escript.build` creates one executable file named `jido`. It bundles the
Elixir application, its BEAM dependencies, and the model/time-zone data needed at
runtime. On first use, those resource files are unpacked under the system temporary
directory. The executable still requires a compatible Erlang/OTP installation on
the target machine. A Homebrew formula should therefore depend on `erlang`.

## Use

Set the provider credential required by the built-in Jido agent, then start the TUI:

```sh
export OPENAI_API_KEY=...
./jido
```

The first spike uses an agent defined inside the package. It does not accept an agent
JSON or YAML file. It requires Erlang/OTP 28 or newer for raw terminal input.

## Homebrew packaging

Build artifacts are tied to the Erlang/OTP major version used at build time. Build one
`jido` artifact per supported platform/OTP combination, publish checksums, and install
it from a formula with an Erlang runtime dependency:

```ruby
depends_on "erlang"

def install
  bin.install "jido"
end
```
