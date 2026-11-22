"""Run and verify the optional MovieLens GDS analysis against local Neo4j."""

import argparse
from collections import defaultdict, deque
from heapq import heappop, heappush
from html import escape
import json
from math import inf, isclose
import os
from pathlib import Path
import re
from statistics import mean
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
QUERIES = ROOT / "queries/part5_gds.cypher"
USER_GRAPH = "ml1m_hw3_co_liked_users_v1"


def statements():
    text = QUERIES.read_text(encoding="utf-8")
    blocks = re.split(r"^// RESULT: (\w+)\n", text, flags=re.MULTILINE)[1:]
    return [(name, block.strip().removesuffix(";")) for name, block in zip(blocks[::2], blocks[1::2])]


def find_hops(neighbors, start, end):
    seen = {start}
    queue = deque([(start, 0)])
    while queue:
        node, depth = queue.popleft()
        if node == end:
            return depth
        for next_node in neighbors.get(node, {}):
            if next_node not in seen:
                seen.add(next_node)
                queue.append((next_node, depth + 1))
    return None


def find_weighted_cost(neighbors, start, end):
    best = {start: 0.0}
    queue = [(0.0, start)]
    while queue:
        cost, node = heappop(queue)
        if node == end:
            return cost
        if cost > best[node]:
            continue
        for next_node, weight in neighbors.get(node, {}).items():
            next_cost = cost + 1 / weight
            if next_cost < best.get(next_node, inf):
                best[next_node] = next_cost
                heappush(queue, (next_cost, next_node))
    return None


def validate(report, edges):
    def require(test, message):
        if not test:
            raise ValueError(message)

    user_graph = report["user_projection"][0]
    require(user_graph["arcCount"] == 2 * len(edges), "Undirected arc count mismatch")
    neighbors = defaultdict(dict)
    for edge in edges:
        start, end, weight = edge["source"], edge["target"], edge["weight"]
        require(start < end and end not in neighbors[start] and weight > 0, "Invalid projected edge")
        neighbors[start][end] = neighbors[end][start] = weight

    communities = report["communities"]
    louvain = report["louvain"][0]
    require(sum(row["users"] for row in communities) == user_graph["nodeCount"], "Lost Louvain users")
    require(len(communities) == louvain["communityCount"], "Louvain community count mismatch")
    for row in communities:
        genres = row["topGenres"]
        require(len(genres) <= 3 and genres == sorted(genres, key=lambda v: (-v["highRatings"], v["genre"])),
                "Top genre rows have the wrong size or order")
    movies = report["pagerank"]
    require(len(movies) == min(10, report["film_projection"][0]["nodeCount"]), "PageRank result count mismatch")
    require(all(m["score"] >= 0 and m["highRatings"] <= m["ratings"] for m in movies), "Invalid PageRank report")

    dijkstra = report["dijkstra"][0]
    pair_rows = dijkstra["paths"]
    points = {tuple(sorted((row["sourceUserId"], row["targetUserId"]))) for row in pair_rows}
    require(len(points) == len(pair_rows) == dijkstra["pairCount"], "Duplicate or missing tested user pair")
    hops = []
    for row in pair_rows:
        pair = row["sourceUserId"], row["targetUserId"]
        require(pair[0] != pair[1] and all(user % 15 == 0 for user in pair), "Incorrect pair sampling")
        observed = row["hops"]
        require(find_hops(neighbors, *pair) == observed, f"GDS and BFS hop counts differ for {pair}")
        weighted = find_weighted_cost(neighbors, *pair)
        if observed is None:
            require(weighted is None and row["weightedRoute"] is None, f"Invented path for disconnected {pair}")
            continue
        hops.append(observed)
        require(row["intermediateUsers"] == observed - 1, f"Incorrect intermediary count for {pair}")
        for route in (row["hopRoute"], row["weightedRoute"]):
            require((route[0], route[-1]) == pair, f"Incorrect route endpoints for {pair}")
            require(all(b in neighbors[a] for a, b in zip(route, route[1:])), f"Nonexistent route edge for {pair}")
        require(len(row["hopRoute"]) == observed + 1, f"Incorrect route length for {pair}")
        require(len(row["weightedRoute"]) == row["weightedHops"] + 1 and row["weightedHops"] >= observed,
                f"Invalid weighted hop count for {pair}")
        route_cost = sum(1 / neighbors[a][b] for a, b in zip(row["weightedRoute"], row["weightedRoute"][1:]))
        require(isclose(weighted, row["weightedCost"], abs_tol=1e-10)
                and isclose(weighted, route_cost, abs_tol=1e-10), f"Invalid weighted cost for {pair}")
    require(len(hops) == dijkstra["reachablePairs"], "Reachable count mismatch")
    require(len(pair_rows) - len(hops) == dijkstra["unreachablePairs"], "Unreachable count mismatch")
    require((hops and isclose(mean(hops), dijkstra["meanHops"])) or (not hops and dijkstra["meanHops"] is None),
            "Mean hop count mismatch")
    return len(edges), len(pair_rows)


def path_svg(dijkstra):
    reached = [row for row in dijkstra["paths"] if row["hopRoute"]]
    if not reached:
        return None
    sample = max(reached, key=lambda row: (row["weightedHops"] - row["hops"], row["hops"], -row["pair"]))
    width = max(800, 100 + 100 * max(len(sample["hopRoute"]), len(sample["weightedRoute"])))
    output = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} 295" role="img" aria-labelledby="title desc">',
        '<title id="title">Два маршрути Дейкстри на MovieLens 1M</title>',
        '<desc id="desc">Кола — користувачі; підпис — userId. Лінії — зв’язки через спільні високі оцінки.</desc>',
        f'<rect width="{width}" height="295" fill="#fbfbf8"/>',
        '<g font-family="system-ui, sans-serif" fill="#182c36">',
        f'<text x="40" y="42" font-size="24" font-weight="bold">MovieLens 1M: шлях {sample["sourceUserId"]} ↔ {sample["targetUserId"]}</text>',
    ]
    for y, route, color, subtitle in (
        (110, sample["hopRoute"], "#245985", f'Мінімум переходів: {sample["hops"]}'),
        (211, sample["weightedRoute"], "#8b472e",
         f'Мінімум суми 1/вага: {sample["weightedHops"]} переходів, вартість {sample["weightedCost"]:.4f}'),
    ):
        positions = [60 + index * (width - 120) / (len(route) - 1) for index in range(len(route))]
        output.append(f'<text x="40" y="{y - 35}" font-size="16">{escape(subtitle)}</text>')
        output.append(f'<path d="M{positions[0]:.1f},{y} H{positions[-1]:.1f}" stroke="{color}" stroke-width="3"/>')
        for x, user in zip(positions, route):
            output.append(f'<circle cx="{x:.1f}" cy="{y}" r="10" fill="{color}"/>')
            output.append(f'<text x="{x:.1f}" y="{y + 32}" text-anchor="middle" font-size="15">{user}</text>')
    output.append('<text x="40" y="275" font-size="14">Вага ребра — число фільмів з оцінкою ≥4 від обох користувачів.</text>')
    return "\n".join([*output, "</g></svg>", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uri", default=os.getenv("NEO4J_URI", "bolt://127.0.0.1:7687"))
    parser.add_argument("--database", default=os.getenv("NEO4J_DATABASE", "neo4j"))
    parser.add_argument("--output-dir", type=Path, default=ROOT / "results")
    args = parser.parse_args()
    parsed = urlsplit(args.uri)
    if parsed.scheme != "bolt" or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        parser.error("Use a local bolt:// URI")
    from neo4j import GraphDatabase, Query

    password = os.getenv("NEO4J_PASSWORD")
    auth = (os.getenv("NEO4J_USER", "neo4j"), password) if password else None
    active = set()
    report = {}
    with GraphDatabase.driver(args.uri, auth=auth) as driver, driver.session(database=args.database) as session:
        try:
            for name, statement in statements():
                print(f"Running {name}…", flush=True)
                report[name] = session.run(Query(statement, timeout=180)).data()
                if name in {"film_projection", "user_projection"}:
                    active.add(report[name][0]["graphName"])
                elif name in {"drop_users", "drop_films"}:
                    active.discard(report[name][0]["graphName"])
                if name == "dijkstra":
                    edges = session.run(Query(
                        "CALL gds.graph.relationshipProperty.stream($name, 'weight') "
                        "YIELD sourceNodeId, targetNodeId, propertyValue "
                        "WITH gds.util.asNode(sourceNodeId).userId AS source, "
                        "gds.util.asNode(targetNodeId).userId AS target, propertyValue AS weight "
                        "WHERE source < target RETURN source, target, weight", timeout=60
                    ), name=USER_GRAPH).data()
                    edge_count, pair_count = validate(report, edges)
                    print(f"Verified {edge_count} undirected edges and {pair_count} pairs with independent BFS/heapq checks.",
                          flush=True)
        finally:
            for graph in active:
                session.run("CALL gds.graph.drop($name, false)", name=graph).consume()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    destination = args.output_dir / "part5_gds.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    if picture := path_svg(report["dijkstra"][0]):
        (args.output_dir / "part5_paths.svg").write_text(picture, encoding="utf-8")
    print(f"Results: {destination}")


if __name__ == "__main__":
    main()
