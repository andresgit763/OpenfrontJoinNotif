# Third-party notices

`lobby-decoder.js` is a browser bundle of OpenFrontIO's lobby decoder and its
runtime dependencies. It is pinned to the commit deployed at openfront.io when
this repair was made:

- Repository: <https://github.com/openfrontio/OpenFrontIO>
- Commit: `8b45be57542f5f8cce8380c4a75d816674a1dabe`
- OpenFrontIO license: GNU Affero General Public License v3.0
- Zod license: MIT

The commit is read from the deployed site's `window.BOOTSTRAP_CONFIG.gitCommit`,
because OpenFront's zbin protocol intentionally has no version marker and must
be decoded with the matching schema.
