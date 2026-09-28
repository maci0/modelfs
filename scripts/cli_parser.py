#!/usr/bin/env python3
"""argparse base that capitalizes the usage line, shared by the CLIs that use it.

scripts/test_scripts_help.sh pins every contributor command to a help line
starting "Usage:", the way the shell scripts print theirs. argparse spells its
own lowercase, so each CLI would otherwise carry the same two overrides and
drift apart. Direct invocation is not a command: this file is imported by
sbom.py and run_benchmarks_and_plots.py.
"""

import argparse
import sys
from typing import override


class Parser(argparse.ArgumentParser):
    @override
    def format_usage(self) -> str:
        return super().format_usage().replace("usage:", "Usage:", 1)

    @override
    def format_help(self) -> str:
        return super().format_help().replace("usage:", "Usage:", 1)


def main(argv: list[str]) -> int:
    """Direct invocation is not a command: this file is imported by the other CLIs."""
    help_only = argv[1:] == ["-h"] or argv[1:] == ["--help"]
    print(
        "Usage: import cli_parser from sbom.py or run_benchmarks_and_plots.py "
        "(not a standalone command)",
        file=sys.stdout if help_only else sys.stderr,
    )
    return 0 if help_only else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
