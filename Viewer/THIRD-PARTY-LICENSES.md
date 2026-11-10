# Viewer license inventory

`dist/THIRD-PARTY-NOTICES.txt` is assembled from the checked-in notice files in `licenses/` and the pinned npm package licenses during `npm run build`.

The Swagger bundle notice snapshot is a conservative inventory of the upstream Swagger UI 5.34.1 production dependency tree. It records package names, versions, license identifiers, authors, repositories, and the license or notice files shipped in those packages. It is a dependency-tree inventory, not a claim that every listed package is present in the final JavaScript bundle. The bundle’s own `.LICENSE.txt` notice is included separately.

The inventory source is the official [Swagger UI v5.34.1 package lock](https://github.com/swagger-api/swagger-ui/blob/v5.34.1/package-lock.json). Its SHA-256 is `ae4719a2ff5450b3cfc25e16ea557b89b6133111eb27814dac6b516c2ae8b503`. The build also includes the full normalize.css 7.0.0 MIT license, YAML ISC license, jsonc-parser MIT license, Swagger UI Apache license and NOTICE, and the legal comment emitted by esbuild.

To refresh the Swagger inventory after changing the bundled Swagger UI version, check out the matching upstream tag, verify the package lock hash, install its production dependency tree with `npm ci --omit=dev --ignore-scripts`, then regenerate the package/version/license mapping and append every shipped `LICENSE`, `COPYING`, and `NOTICE` file. Check packages without standalone license files against their published license metadata and include the applicable full license text. Update this inventory’s source version and hash, then run the root `npm run build` and review the generated notices.
