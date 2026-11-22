// Neo4j GDS: тільки каталог у пам’яті; базу даних не змінюємо.
// Для повтору дочекайтеся кінцевих DROP. Якщо перервано, видаліть лише власні
// дві проєкції з назвами, наведеними нижче, або запустіть scripts/run_part5.py.

// RESULT: versions
CALL dbms.components() YIELD name, versions
WHERE name = 'Neo4j Kernel'
RETURN versions[0] AS neo4jVersion, gds.version() AS gdsVersion;

// RESULT: film_projection
// До розкриття пар відберемо 300 найчастіше оцінених фільмів (>20 оцінок).
// Вага — число користувачів, які дали обом оцінки ≥4. Ліміт після агрегації
// залишає до 15 000 найсильніших зв’язків, із визначеним порядком за нічиєї.
CALL () {
  MATCH (film:Movie)<-[r:RATED]-(:User)
  WITH film, count(r) AS ratingCount
  WHERE ratingCount > 20
  WITH film, ratingCount ORDER BY ratingCount DESC, film.movieId LIMIT 300
  RETURN collect(film) AS eligible
}
CALL (eligible) {
  UNWIND eligible AS source
  RETURN source, null AS target, null AS strength
  UNION ALL
  UNWIND eligible AS film
  MATCH (film)<-[r:RATED]-(u:User)
  WHERE r.rating >= 4
  WITH u, collect(film) AS liked
  WHERE size(liked) >= 2
  UNWIND range(0, size(liked) - 2) AS i
  UNWIND range(i + 1, size(liked) - 1) AS j
  WITH liked[i] AS first, liked[j] AS second
  WITH CASE WHEN first.movieId < second.movieId THEN first ELSE second END AS source,
       CASE WHEN first.movieId < second.movieId THEN second ELSE first END AS target
  WITH source, target, count(*) AS strength
  ORDER BY strength DESC, source.movieId, target.movieId LIMIT 15000
  RETURN source, target, strength
}
WITH gds.graph.project(
  'ml1m_hw3_co_liked_films_v1', source, target,
  {sourceNodeLabels: ['Movie'], targetNodeLabels: ['Movie'],
   relationshipType: 'CO_LIKED', relationshipProperties: {weight: coalesce(toFloat(strength), 1.0)}},
  {undirectedRelationshipTypes: ['CO_LIKED'], readConcurrency: 1}
) AS graph
RETURN graph.graphName AS graphName, graph.nodeCount AS nodeCount, graph.relationshipCount AS arcCount;

// RESULT: pagerank
// Додаткові лічильники показують, що центральність та кількість оцінок різні.
CALL gds.pageRank.stream('ml1m_hw3_co_liked_films_v1', {
  relationshipWeightProperty: 'weight', dampingFactor: 0.85,
  maxIterations: 100, tolerance: 0.000000001, concurrency: 1
}) YIELD nodeId, score
WITH gds.util.asNode(nodeId) AS film, score
ORDER BY score DESC, film.movieId LIMIT 10
MATCH (film)<-[r:RATED]-(:User)
RETURN film.movieId AS movieId, film.title AS title, film.year AS year, score,
       count(r) AS ratings, count(CASE WHEN r.rating >= 4 THEN 1 END) AS highRatings
ORDER BY score DESC, movieId;

// RESULT: user_projection
// Кожен 15-й userId: визначена підвибірка користувачів до розкриття пар.
// Вага — число фільмів з оцінкою ≥4 від обох; відстань — її обернена.
// Гілка з target=null додає користувачів навіть якщо жодне ребро не залишилося.
CALL () {
  MATCH (u:User)
  WHERE u.userId % 15 = 0
  WITH u ORDER BY u.userId
  RETURN collect(u) AS eligible
}
CALL (eligible) {
  UNWIND eligible AS source
  RETURN source, null AS target, null AS strength
  UNION ALL
  UNWIND eligible AS u
  MATCH (u)-[r:RATED]->(film:Movie)
  WHERE r.rating >= 4
  WITH film, collect(u) AS likedBy
  WHERE size(likedBy) >= 2
  UNWIND range(0, size(likedBy) - 2) AS i
  UNWIND range(i + 1, size(likedBy) - 1) AS j
  WITH likedBy[i] AS first, likedBy[j] AS second
  WITH CASE WHEN first.userId < second.userId THEN first ELSE second END AS source,
       CASE WHEN first.userId < second.userId THEN second ELSE first END AS target
  WITH source, target, count(*) AS strength
  ORDER BY strength DESC, source.userId, target.userId LIMIT 15000
  RETURN source, target, strength
}
WITH gds.graph.project(
  'ml1m_hw3_co_liked_users_v1', source, target,
  {sourceNodeLabels: ['User'], targetNodeLabels: ['User'], relationshipType: 'CO_LIKED',
   relationshipProperties: {weight: coalesce(toFloat(strength), 1.0), distance: 1.0 / coalesce(strength, 1)}},
  {undirectedRelationshipTypes: ['CO_LIKED'], readConcurrency: 1}
) AS graph
RETURN graph.graphName AS graphName, graph.nodeCount AS nodeCount, graph.relationshipCount AS arcCount;

// RESULT: louvain
// mutate додає ознаку лише до проєкції GDS.
CALL gds.louvain.mutate('ml1m_hw3_co_liked_users_v1', {
  mutateProperty: 'community', relationshipWeightProperty: 'weight',
  maxLevels: 10, tolerance: 0.00001, concurrency: 1
}) YIELD communityCount, modularity, modularities, nodePropertiesWritten
RETURN communityCount, modularity, modularities, nodePropertiesWritten;

// RESULT: communities
// Перші 10 рядків — найбільші спільноти. Для жанрів рахуємо по одному
// голосу за кожну пару «висока оцінка, жанр»: багатожанровий фільм може
// додати голос одразу до кількох жанрів. Беремо всі вподобані фільми учасників.
CALL gds.graph.nodeProperty.stream('ml1m_hw3_co_liked_users_v1', 'community')
YIELD nodeId, propertyValue
WITH toInteger(propertyValue) AS community, collect(gds.util.asNode(nodeId)) AS members
CALL (members) {
  UNWIND members AS user
  MATCH (user)-[r:RATED]->(:Movie)-[:HAS_GENRE]->(g:Genre)
  WHERE r.rating >= 4
  WITH g.name AS genre, count(*) AS highRatings
  ORDER BY highRatings DESC, genre
  RETURN collect({genre: genre, highRatings: highRatings})[..3] AS topGenres
}
RETURN community, size(members) AS users, topGenres
ORDER BY users DESC, community;

// RESULT: dijkstra
// Параметри пар визначені до перевірки зв'язності. Для «рукостискань»
// використовуємо незважені переходи; окремо порівнюємо шлях за 1/weight.
MATCH (u:User)
WHERE u.userId % 15 = 0
WITH u ORDER BY u.userId
WITH collect(u) AS users
WHERE size(users) >= 2
WITH users, size(users) AS total
UNWIND range(0, CASE WHEN total < 24 THEN total - 1 ELSE 23 END) AS pair
WITH users, total, pair, (13 * pair + 7) % total AS i, (37 * pair + 113) % total AS j
WITH pair, users[i] AS source, users[CASE WHEN j = i THEN (j + 1) % total ELSE j END] AS target
CALL (source, target) {
  CALL gds.shortestPath.dijkstra.stream('ml1m_hw3_co_liked_users_v1', {
    sourceNode: source, targetNodes: [target], logProgress: false
  }) YIELD nodeIds
  RETURN head(collect([id IN nodeIds | gds.util.asNode(id).userId])) AS shortest
}
CALL (source, target) {
  CALL gds.shortestPath.dijkstra.stream('ml1m_hw3_co_liked_users_v1', {
    sourceNode: source, targetNodes: [target], relationshipWeightProperty: 'distance', logProgress: false
  }) YIELD nodeIds, totalCost
  RETURN head(collect({route: [id IN nodeIds | gds.util.asNode(id).userId], cost: totalCost})) AS weighted
}
WITH pair, source, target, shortest, weighted ORDER BY pair
RETURN count(*) AS pairCount, count(shortest) AS reachablePairs,
       count(*) - count(shortest) AS unreachablePairs,
       avg(size(shortest) - 1) AS meanHops, max(size(shortest) - 1) AS maxHops,
       avg(size(weighted.route) - 1) AS meanWeightedHops,
       collect({pair: pair + 1, sourceUserId: source.userId, targetUserId: target.userId,
                hopRoute: shortest, hops: size(shortest) - 1,
                intermediateUsers: size(shortest) - 2, weightedRoute: weighted.route,
                weightedHops: size(weighted.route) - 1, weightedCost: weighted.cost}) AS paths;

// RESULT: drop_users
CALL gds.graph.drop('ml1m_hw3_co_liked_users_v1') YIELD graphName RETURN graphName;

// RESULT: drop_films
CALL gds.graph.drop('ml1m_hw3_co_liked_films_v1') YIELD graphName RETURN graphName;
