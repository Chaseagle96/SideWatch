#!/usr/bin/env python3
"""Compatibility entry point for Watch-required recursive IPA validation."""

from validate_ipa import main


if __name__ == "__main__":
    raise SystemExit(main(default_require_watch=True))
