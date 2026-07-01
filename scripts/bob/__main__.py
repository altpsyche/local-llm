"""`python -m bob` entry point (NB4)."""
import sys

from bob.cli import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
