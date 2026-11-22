// Ступінь — інцидентні ребра базової схеми RATED / HAS_GENRE.
// Поріг оцінюємо окремо для User, Movie і Genre.
// Евристика: ступінь >= дискретного p95 і > 2 * дискретної медіани.
MATCH (node)
WHERE node:User OR node:Movie OR node:Genre
WITH CASE WHEN node:User THEN 'User' WHEN node:Movie THEN 'Movie' ELSE 'Genre' END AS label,
     coalesce(toString(node.userId), toString(node.movieId), node.name) AS nodeId,
     coalesce(node.title, node.name, 'Користувач ' + toString(node.userId)) AS name,
     COUNT { (node)-[:RATED|HAS_GENRE]-() } AS degree
ORDER BY degree DESC, nodeId
WITH label, count(*) AS nodeCount, percentileDisc(degree, 0.5) AS medianDegree,
     percentileDisc(degree, 0.95) AS p95Degree, max(degree) AS maxDegree,
     collect({nodeId: nodeId, name: name, degree: degree}) AS byDegree
WITH label, nodeCount, medianDegree, p95Degree, maxDegree,
     [row IN byDegree WHERE row.degree >= p95Degree AND row.degree > 2 * medianDegree] AS anomalies
RETURN label, nodeCount, medianDegree, p95Degree, maxDegree,
       size(anomalies) AS anomalyCount, anomalies[..10] AS topAnomalies
ORDER BY label;

// Однакові операції з вузлами того самого типу й тим самим індексом.
// 2858 — максимальний ступінь Movie (3430), 1606 — типовий (медіана 111).
// Навмисно перевіряємо властивість ребра: метаданих про ступінь тут недостатньо.
PROFILE
MATCH (movie:Movie {movieId: 2858})<-[rated:RATED]-(:User)
WHERE rated.rating >= 4
RETURN movie.movieId AS movieId, count(rated) AS highRatings;

PROFILE
MATCH (movie:Movie {movieId: 1606})<-[rated:RATED]-(:User)
WHERE rated.rating >= 4
RETURN movie.movieId AS movieId, count(rated) AS highRatings;
