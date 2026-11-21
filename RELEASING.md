# Releasing minga_claude_bridge

Publishing to Hex is public and permanent after a short revert window, so only the maintainer publishes, from their own Hex account. This checklist prepares a release so that the publish step is the only thing left.

## Publish order

The bridge compiles against `minga_sdk`. Publish the SDK first, from `sdk/` in jsmestad/minga, following that repo's `docs/RELEASING.md`. Publish the bridge only after the SDK version it needs is on Hex.

## Checklist

1. **Start from a green `main`.** CI passes on the commit you release.

2. **Bump the version and the changelog.**
   - Set `@version` in `mix.exs` and the version in `lib/minga_claude_bridge/version.ex`. The version test fails when they disagree.
   - Move the `Unreleased` entry in `CHANGELOG.md` to the new version with today's date, and add its link to the Hex release page.

3. **Check the `minga_sdk` dependency.** It must stay the Hex line with `only: [:dev, :test]`:

   ```elixir
   {:minga_sdk, "~> 0.1", only: [:dev, :test], runtime: false},
   ```

   Minga provides the real modules at runtime. Without `only`, `minga_sdk` becomes a runtime dependency, and installing the bridge in Minga compiles SDK stubs that shadow Minga's modules. If the bridge needs a newer SDK, publish that SDK first and raise the requirement here.

4. **Build and review the package.**

   ```sh
   mix hex.build --unpack -o /tmp/minga_claude_bridge-pkg
   ```

   - The file list holds only `lib/`, `mix.exs`, `README.md`, `CHANGELOG.md`, and `LICENSE`. Nothing from `test/` or `deps/`.
   - The printed metadata has no `Dependencies` section: no runtime dependency on `minga_sdk`, `minga`, or `req_llm`. Check `/tmp/minga_claude_bridge-pkg/hex_metadata.config` as well; its `requirements` list is empty.
   - `mix docs` builds and the README renders as the main page.

5. **Publish (maintainer only).**

   ```sh
   mix hex.publish
   ```

   Review the package and docs summary Hex prints before confirming. The docs link sources to `main` (`source_ref`).

6. **Verify the install.** In a Minga without a checkout of either repo, declare only:

   ```elixir
   extension :claude_bridge, hex: "minga_claude_bridge", app: :minga_claude_bridge, version: "~> 0.1"
   ```

   `:extensions` lists `claude_bridge [running] (hex: minga_claude_bridge)`, `/model` shows "Claude (subscription)", and a prompt streams a reply. Record the commands and output in the release PR.
