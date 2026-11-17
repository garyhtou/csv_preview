# Security policy

Built for untrusted uploads: it reads at most 2 MiB, stops after 5 seconds, and never runs another program or opens a network connection.

csv_preview turns files that strangers upload into images, so its security matters. This page explains how to report a vulnerability, which versions receive fixes, and what csv_preview does and does not defend against.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** ([direct link](https://github.com/garyhtou/csv_preview/security/advisories/new)). Please do not open a public issue, pull request or discussion about a vulnerability.

Include what you can: the csv_preview, Ruby and libvips versions, the input that triggers the problem (or a script that generates it), the options used, and what happens. Keep real personal data out of the report; a generated file is better.

csv_preview is maintained by a volunteer, and reports are handled on a best-effort basis, so there is no promised response time. You will hear back once the report has been read, and again when there is a fix or a decision.

## Supported versions

Before 1.0, security fixes are released for the latest minor version only. Upgrade to the newest release to receive them.

| Version | Security fixes |
|---|---|
| 0.1.x | Yes |

## Disclosure

Disclosure is coordinated: a fix is prepared privately, released, and then announced. Each fix ships with a GitHub Security Advisory (with a CVE when warranted), which feeds Dependabot alerts, and with a pull request to the [Ruby Advisory Database](https://github.com/rubysec/ruby-advisory-db), which feeds `bundle audit`. Reporters are credited in the advisory unless they prefer not to be.

## Threat model

- **Who:** anyone who can upload a file to an application that previews it. Previews are usually generated automatically, in a background job or a web request, so nobody reviews a file before csv_preview reads it.
- **What they control:** every byte of the file.
- **Where the bytes go:** csv_preview's Ruby reader and parser (built on Ruby's `csv` library) read at most `max_input_bytes`. Only sanitised, escaped and truncated cell text then reaches Pango and HarfBuzz, through libvips, to be shaped and drawn. The output PNG goes to the application's variant processor and to browsers.
- **Where the bytes never go:** an image decoder, a subprocess, the network, `eval`, or a file written by csv_preview. (In Rails, Active Storage itself downloads a blob to a temporary file only for storage services that cannot serve ranged reads.)
- **What csv_preview guarantees for any input:** bounded bytes read; bounded work, memory and time; a bounded image size; formulas, markup and bidirectional control characters never interpreted; no side effects; and error messages that never include the input. The README's [Security](https://github.com/garyhtou/csv_preview#security) section lists each guarantee with the test that proves it, and the honest limits.

### In scope

- Crashes, hangs, or time or memory use beyond the documented bounds, caused by a file or by options.
- Cell text that is interpreted instead of drawn literally: markup, formulas, or bidirectional control characters that reorder what is shown.
- Anything that makes csv_preview start a process, open a socket, write a file, or pass input bytes to an image decoder.
- Error messages, log lines or instrumentation events that include file content.
- The Active Storage previewer reading more of a blob than `max_input_bytes` on services that support ranged reads.

### Out of scope

Report these to the project concerned, and tell us too if csv_preview could mitigate them:

- Bugs inside libvips, Pango, HarfBuzz, FreeType, cairo or fontconfig.
- ImageMagick in the application's own variant pipeline (csv_preview never uses it).
- Floods of uploads; rate limiting is the application's job.
- CSV injection when someone opens the original file in a spreadsheet program. csv_preview never modifies or re-exports the file.
- Who can see a preview image. It shows the first rows of the file, so applications must serve it with the same authorisation as the original.
