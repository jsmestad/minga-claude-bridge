# Releasing minga_claude_bridge

Publishing to Hex is public and permanent after a short revert window, so only the maintainer publishes, from their own Hex account. This checklist prepares a release so that the publish step is the only thing left.

## Publish order

The bridge compiles against `minga_sdk`. Publish the SDK first, from `sdk/` in jsmestad/minga, following that repo's `docs/RELEASING.md`. Publish the bridge only after the SDK version it needs is on Hex.

## Checklist

1. **Start from a green `main`.** CI passes on the commit you release.

2. **Bump the version and the changelog.**
   - Set `@version` in `mix.exs` and the version in `lib/minga_claude_bridge/version.ex`. The version test fails when they disagree.
   - Move the `Unreleased` entry in `CHANGELOG.md` to the new version with today's date, and add the link for the tag.

3. **Switch `minga_sdk` to Hex.** Replace the git dependency in `mix.exs` with the Hex line from its `TODO(release)` comment:

   ```elixir
   {:minga_sdk, "~> 0.2", only: [:dev, :test], runtime: false},
   ```

   Keep `only: [:dev, :test]`. Minga provides the real modules at runtime. Without `only`, `minga_sdk` becomes a runtime dependency, and installing the bridge in Minga compiles SDK stubs that shadow Minga's modules. Run `mix deps.get`, then the checks: `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix format --check-formatted`.

4. **Build and review the package.**

   ```sh
   mix hex.build --unpack -o /tmp/minga_claude_bridge-pkg
   ```

   - The file list holds only `lib/`, `mix.exs`, `README.md`, `CHANGELOG.md`, and `LICENSE`. Nothing from `test/` or `deps/`.
   - The printed metadata has no `Dependencies` section: no runtime dependency on `minga_sdk`, `minga`, or `req_llm`. Check `/tmp/minga_claude_bridge-pkg/hex_metadata.config` as well; its `requirements` list is empty.
   - `mix docs` builds and the README renders as the main page.

5. **Tag the release.**

   ```sh
   git tag -a v0.1.0 -m "minga_claude_bridge 0.1.0"
   git push origin v0.1.0
   ```

   The docs link sources to this tag (`source_ref`).

6. **Publish (maintainer only).**

   ```sh
   mix hex.publish
   ```

   Review the package and docs summary Hex prints before confirming.

7. **Verify the install.** In a Minga without a checkout of either repo, declare only:

   ```elixir
   extension :claude_bridge, hex: "minga_claude_bridge", version: "~> 0.1"
   ```

   `:extensions` lists `claude_bridge [running] (hex: minga_claude_bridge)`, `/model` shows "Claude (subscription)", and a prompt streams a reply. Record the commands and output in the release PR.
