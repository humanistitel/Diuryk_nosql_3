// Run against a dedicated MovieLens database. No destructive reset is used.
// Unique constraints create the indexes required by the node lookups.
CREATE CONSTRAINT ml1m_user_id IF NOT EXISTS
FOR (u:User) REQUIRE u.userId IS UNIQUE;

CREATE CONSTRAINT ml1m_movie_id IF NOT EXISTS
FOR (m:Movie) REQUIRE m.movieId IS UNIQUE;

CREATE CONSTRAINT ml1m_genre_name IF NOT EXISTS
FOR (g:Genre) REQUIRE g.name IS UNIQUE;

CALL db.awaitIndexes(120);

LOAD CSV WITH HEADERS FROM 'file:///users.csv' AS row
MERGE (u:User {userId: toInteger(row.userId)})
SET u.gender = row.gender, u.age = toInteger(row.age), u.occupation = toInteger(row.occupation)
RETURN count(u) AS user_rows_applied;

LOAD CSV WITH HEADERS FROM 'file:///movies.csv' AS row
MERGE (m:Movie {movieId: toInteger(row.movieId)})
SET m.title = row.title, m.year = toInteger(row.year)
RETURN count(m) AS movie_rows_applied;

LOAD CSV WITH HEADERS FROM 'file:///movies.csv' AS row
MATCH (m:Movie {movieId: toInteger(row.movieId)})
UNWIND split(row.genres, '|') AS rawGenre
WITH m, trim(rawGenre) AS genre
WHERE genre <> ''
MERGE (g:Genre {name: genre})
MERGE (m)-[:HAS_GENRE]->(g)
RETURN count(*) AS movie_genres_applied;

// Convert and verify all foreign keys before this step. Each row matches existing
// users/movies. Serial batches plus MERGE make re-running the same input safe.
CALL apoc.periodic.iterate(
  "LOAD CSV WITH HEADERS FROM 'file:///ratings.csv' AS row
   RETURN toInteger(row.userId) AS userId, toInteger(row.movieId) AS movieId,
          toInteger(row.rating) AS rating, toInteger(row.timestamp) AS timestamp",
  "MATCH (u:User {userId: userId})
   MATCH (m:Movie {movieId: movieId})
   MERGE (u)-[r:RATED]->(m)
   SET r.rating = rating, r.timestamp = timestamp",
  {batchSize: 5000, parallel: false, retries: 1}
)
YIELD batches, total, committedOperations, failedOperations, failedBatches, errorMessages, updateStatistics
RETURN batches, total, committedOperations, failedOperations, failedBatches, errorMessages, updateStatistics;

MATCH (u:User) RETURN count(u) AS users;
MATCH (m:Movie) RETURN count(m) AS movies;
MATCH (g:Genre) RETURN count(g) AS genres;
MATCH ()-[r:RATED]->() RETURN count(r) AS ratings;
MATCH ()-[r:HAS_GENRE]->() RETURN count(r) AS movie_genres;
SHOW INDEXES YIELD name, state, type, labelsOrTypes, properties
RETURN name, state, type, labelsOrTypes, properties ORDER BY name;
