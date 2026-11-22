"""Convert the official MovieLens 1M Latin-1 files into Neo4j UTF-8 CSVs."""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
YEAR_AT_END = re.compile(r"^(.*?)\s*\(([0-9]{4})\)$")
AGE_GROUPS = {1, 18, 25, 35, 45, 50, 56}


def rows(path, size):
    with path.open(encoding="latin-1", newline="") as input_file:
        for number, line in enumerate(input_file, start=1):
            fields = line.rstrip("\r\n").split("::")
            if len(fields) != size:
                raise ValueError(f"{path.name}:{number}: expected {size} fields, got {len(fields)}")
            yield number, fields


def number(text, name, source, line, low, high):
    try:
        value = int(text)
    except ValueError as error:
        raise ValueError(f"{source}:{line}: {name} is not an integer") from error
    if not low <= value <= high:
        raise ValueError(f"{source}:{line}: {name} must be in {low}–{high}")
    return value


def writer(fp):
    return csv.writer(fp, lineterminator="\n")


def convert(source, output, rating_limit=None):
    output.mkdir(parents=True, exist_ok=True)
    summary = {}
    with TemporaryDirectory(prefix=".movielens-", dir=output) as staging:
        pending = Path(staging)
        users = set()
        age_counts = {}
        with (pending / "users.csv").open("w", encoding="utf-8", newline="") as fp:
            out = writer(fp)
            out.writerow(("userId", "gender", "age", "occupation"))
            for line, (uid, gender, age, occupation, _postal_code) in rows(source / "users.dat", 5):
                uid = number(uid, "userId", "users.dat", line, 1, 2**31-1)
                age = number(age, "age", "users.dat", line, 1, 56)
                occupation = number(occupation, "occupation", "users.dat", line, 0, 20)
                if uid in users or gender not in {"F", "M"} or age not in AGE_GROUPS:
                    raise ValueError(f"users.dat:{line}: duplicate user ID, invalid gender, or invalid age group")
                users.add(uid)
                age_counts[age] = age_counts.get(age, 0) + 1
                out.writerow((uid, gender, age, occupation))

        movies = set()
        genres = set()
        genre_links = 0
        unknown_years = 0
        with (pending / "movies.csv").open("w", encoding="utf-8", newline="") as fp:
            out = writer(fp)
            out.writerow(("movieId", "title", "year", "genres"))
            for line, (mid, title, source_genres) in rows(source / "movies.dat", 3):
                mid = number(mid, "movieId", "movies.dat", line, 1, 2**31-1)
                movie_genres = [g.strip() for g in source_genres.split("|")]
                if mid in movies or not title.strip() or any(not g for g in movie_genres) or len(set(movie_genres)) != len(movie_genres):
                    raise ValueError(f"movies.dat:{line}: duplicate movie ID or invalid title/genres")
                movies.add(mid)
                genres.update(movie_genres)
                genre_links += len(movie_genres)
                match = YEAR_AT_END.fullmatch(title.strip())
                if match:
                    title, year = match.groups()
                else:
                    year = ""
                    unknown_years += 1
                out.writerow((mid, title.strip(), year, "|".join(movie_genres)))

        pairs = set()
        rating_histogram = {value: 0 for value in range(1, 6)}
        rated_movies = set()
        with (pending / "ratings.csv").open("w", encoding="utf-8", newline="") as fp:
            out = writer(fp)
            out.writerow(("userId", "movieId", "rating", "timestamp"))
            for line, (uid, mid, rating, timestamp) in rows(source / "ratings.dat", 4):
                if rating_limit is not None and line > rating_limit:
                    break
                uid = number(uid, "userId", "ratings.dat", line, 1, 2**31-1)
                mid = number(mid, "movieId", "ratings.dat", line, 1, 2**31-1)
                rating = number(rating, "rating", "ratings.dat", line, 1, 5)
                timestamp = number(timestamp, "timestamp", "ratings.dat", line, 0, 2**63-1)
                if uid not in users or mid not in movies:
                    raise ValueError(f"ratings.dat:{line}: unknown user or movie {uid}/{mid}")
                key = (uid << 32) | mid
                if key in pairs:
                    raise ValueError(f"ratings.dat:{line}: duplicate user/movie rating {uid}/{mid}")
                pairs.add(key)
                rated_movies.add(mid)
                rating_histogram[rating] += 1
                out.writerow((uid, mid, rating, timestamp))

        if not users or not movies or not pairs:
            raise ValueError("No usable graph: users.dat, movies.dat, and ratings.dat must be non-empty.")

        summary.update(
            users=len(users), movies=len(movies), genres=len(genres), has_genre=genre_links,
            rated_movies=len(rated_movies), ratings=len(pairs), unknown_movie_years=unknown_years,
            age_groups=age_counts, ratings_by_value=rating_histogram, rating_limit=rating_limit,
            csv_sha256={name: hashlib.sha256((pending / name).read_bytes()).hexdigest()
                        for name in ("users.csv", "movies.csv", "ratings.csv")},
        )
        for name in summary["csv_sha256"]:
            (pending / name).replace(output / name)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "data/ml-1m",
                        help="directory with users.dat, movies.dat, ratings.dat")
    parser.add_argument("--output", type=Path, default=ROOT / "import")
    parser.add_argument("--rating-limit", type=int, help="optional first N ratings for a small test")
    args = parser.parse_args()
    if args.rating_limit is not None and args.rating_limit < 1:
        parser.error("--rating-limit must be positive")
    print(json.dumps(convert(args.source, args.output, args.rating_limit), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
