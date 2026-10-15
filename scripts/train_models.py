"""Model training entry point: train, tune, evaluate and register the tree models.

Usage::

    python -m scripts.train_models                      # both problems, config defaults
    python -m scripts.train_models --problem demand     # one problem
    python -m scripts.train_models --n-trials 10        # faster tuning
    python -m scripts.train_models --no-register        # skip Model Regi   stry
"""

from __future__ import annotations

import argparse
import json
import logging

from src.models.train import train_all

logger = logging.getLogger(__name__)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run model training.")
    parser.add_argument(
        "--problem",
        choices=["demand", "fare", "both"],
        default="both",
        help="Which problem(s) to train (default: both).",
    )
    parser.add_argument(
        "--n-trials",
        type=int,
        default=None,
        help="Optuna trials per estimator (default: config models.n_trials).",
    )
    parser.add_argument(
        "--no-register",
        action="store_true",
        help="Train and log runs but do not register to the MLflow Model Registry.",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )

    problems = None if args.problem == "both" else [args.problem]
    summaries = train_all(
        problems=problems, n_trials=args.n_trials, register=not args.no_register
    )
    print(json.dumps(summaries, indent=2, default=str))


if __name__ == "__main__":
    main()
