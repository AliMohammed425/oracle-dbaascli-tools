# Changelog

## Version 5.0.0 Enterprise Edition - 2026-06-25

- Added shared shell framework: `lib/odaa_common.sh`
- Standardized logging and summary files across scripts
- Added common `-a`, `-d`, `-i`, `-t`, and help behavior
- Added primary/standby side options for create scripts
- Added testing/dry-run mode for safer validation
- Added skip logic for `flagSkip=Y`
- Added existing database skip behavior where `dbaascli database list` is available
- Preserved original scripts under `archive/original_scripts`
- Added GitHub-ready README, LICENSE, CHANGELOG, `.gitignore`
- Added documentation under `docs/USER_GUIDE.md`
