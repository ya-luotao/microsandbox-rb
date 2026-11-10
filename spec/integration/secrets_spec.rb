# frozen_string_literal: true

# Real microVM coverage for the runtime v0.7 secrets vocabulary: the guest only
# ever sees the placeholder, never the value. Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "secrets (runtime v0.7 vocabulary)", :integration do
  let(:image) { default_test_image }
  let(:value) { "sk-live-#{rand(1_000_000_000)}" }

  it "exposes only the placeholder to the guest, with the full v0.7 policy accepted by the runtime" do
    Microsandbox::Sandbox.create(
      unique_sandbox_name("rb-secrets"), image: image,
      secrets: [
        {env: "API_KEY", value: value, allow: ["api.example.com", "*.example.org"],
         allow_placeholder_for: ["internal.example"], require_tls_identity: true,
         violation_action: :block_and_terminate,
         substitution: {headers: true, header_fields: ["Authorization"], query: true}},
        {env: "OTHER", value: "#{value}-2", allow: ["api.example.net"], placeholder: "PLACEHOLDER_OTHER"}
      ],
      secret_violation_action: :block
    ) do |sb|
      expect(sb.exec("sh", ["-c", "printf %s \"$API_KEY\""]).stdout).to eq("$MSB_API_KEY")
      expect(sb.exec("sh", ["-c", "printf %s \"$OTHER\""]).stdout).to eq("PLACEHOLDER_OTHER")
      environment = sb.exec("env").stdout
      expect(environment).not_to include(value)
    end
  end
end
