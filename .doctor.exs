%Doctor.Config{
  # Internal implementation modules — the interactive terminal UI and the
  # OTP terminal adapter are not part of the public API surface. The public
  # modules under Jido.Console and Jido.Console.Automation remain fully documented.
  ignore_modules: [
    ~r/^Jido\.Console\.MixProject$/,
    ~r/^Jido\.Console\.Release\.ForbiddenEnvironmentAdapter$/,
    ~r/^Jido\.Console\.Tui(?:\.|$)/,
    ~r/^Jido\.Console\.Terminal\.OTP(?:\.|$)/
  ],
  ignore_paths: [],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 100,
  min_overall_doc_coverage: 80,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 80,
  exception_moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Summary,
  struct_type_spec_required: true,
  umbrella: false
}
