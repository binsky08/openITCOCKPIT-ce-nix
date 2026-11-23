# `nix run .#update-test-images` re-pins tests/images.json (used by
# test-full-stack) to the current upstream images of nix/containers.nix.
{
  lib,
  writeShellApplication,
  nix-prefetch-docker,
  jq,
}:
let
  services = builtins.toJSON (
    lib.mapAttrs (_: d: {
      inherit (d) image;
      tag = d.tag or "latest";
    }) (import ../nix/containers.nix)
  );
in
writeShellApplication {
  name = "update-test-images";
  runtimeInputs = [
    nix-prefetch-docker
    jq
  ];
  text = ''
    out=''${1:-tests/images.json}
    jq -r 'to_entries[] | "\(.key) \(.value.image) \(.value.tag)"' <<< ${lib.escapeShellArg services} |
      while read -r name image tag; do
        echo "Prefetching $image:$tag" >&2
        nix-prefetch-docker --image-name "$image" --image-tag "$tag" \
          --final-image-name "$image" --final-image-tag "$tag" \
          --os linux --arch amd64 --json --quiet |
          jq --arg n "$name" '{($n): .}'
      done | jq -s 'add' > "$out.tmp"
    mv "$out.tmp" "$out"
    echo "Wrote $out" >&2
  '';
}
