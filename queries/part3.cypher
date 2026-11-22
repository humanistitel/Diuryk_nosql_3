// Q1: усі трилери із середньою оцінкою строго понад 4.0.
MATCH (:Genre {name: 'Thriller'})<-[:HAS_GENRE]-(movie:Movie)<-[rated:RATED]-(:User)
WITH movie, avg(rated.rating) AS avgRating, count(rated) AS ratingCount
WHERE avgRating > 4.0
RETURN movie.movieId AS movieId, movie.title AS title, avgRating, ratingCount
ORDER BY avgRating DESC, ratingCount DESC, movieId;

// Q2: саме фільми з оцінкою 5; рівно 50 не проходить поріг.
MATCH (user:User)-[rated:RATED]->(movie:Movie)
WHERE rated.rating = 5
WITH user, count(DISTINCT movie) AS fiveStarMovies
WHERE fiveStarMovies > 50
RETURN user.userId AS userId, fiveStarMovies
ORDER BY fiveStarMovies DESC, userId;

// Q3: перетин оцінок >= 4 для користувачів 1 і 2.
MATCH (:User {userId: 1})-[first:RATED]->(movie:Movie)<-[second:RATED]-(:User {userId: 2})
WHERE first.rating >= 4 AND second.rating >= 4
RETURN movie.movieId AS movieId, movie.title AS title,
       first.rating AS ratingUser1, second.rating AS ratingUser2
ORDER BY movieId;

// Q4: усі рейтинги фільмів жанру, а також частка оцінок >= 4.
// Оцінку багатожанрового фільму слід врахувати один раз у кожному його жанрі.
MATCH (genre:Genre)<-[:HAS_GENRE]-(movie:Movie)
OPTIONAL MATCH (movie)<-[rated:RATED]-(:User)
WITH genre, count(DISTINCT movie) AS movieCount, count(rated) AS ratingCount,
     avg(rated.rating) AS avgRating,
     sum(CASE WHEN rated.rating >= 4 THEN 1 ELSE 0 END) AS highRatings
RETURN genre.name AS genre, movieCount, ratingCount, avgRating, highRatings,
       CASE WHEN ratingCount = 0 THEN null ELSE 1.0 * highRatings / ratingCount END AS highShare
ORDER BY avgRating DESC, ratingCount DESC, genre;

// Q5: рекомендації користувачу 1. Подібність — Jaccard множин оцінених >= 4 фільмів.
// Щонайменше 3 спільні вподобання, до 50 найближчих сусідів, від 3 голосів за фільм.
MATCH (target:User {userId: 1})
WITH target, COUNT {
  (target)-[r:RATED]->(:Movie) WHERE r.rating >= 4
} AS targetLiked
MATCH (target)-[targetRating:RATED]->(shared:Movie)<-[peerRating:RATED]-(peer:User)
WHERE peer <> target AND targetRating.rating >= 4 AND peerRating.rating >= 4
WITH target, targetLiked, peer, count(DISTINCT shared) AS commonLiked
WHERE commonLiked >= 3
WITH target, peer, commonLiked, targetLiked, COUNT {
  (peer)-[r:RATED]->(:Movie) WHERE r.rating >= 4
} AS peerLiked
WITH target, peer, 1.0 * commonLiked / (targetLiked + peerLiked - commonLiked) AS similarity
ORDER BY similarity DESC, peer.userId
LIMIT 50
MATCH (peer)-[rated:RATED]->(candidate:Movie)
WHERE rated.rating >= 4 AND NOT EXISTS { (target)-[:RATED]->(candidate) }
WITH candidate, count(DISTINCT peer) AS supportingUsers, avg(rated.rating) AS meanPeerRating,
     sum(similarity * (rated.rating - 3)) AS score
WHERE supportingUsers >= 3
RETURN candidate.movieId AS movieId, candidate.title AS title,
       supportingUsers, meanPeerRating, round(score, 8) AS recommendationScore
ORDER BY recommendationScore DESC, supportingUsers DESC, movieId
LIMIT 10;

// Q6: 1 і 46 не мають спільних оцінених фільмів; шлях чергує User та Movie.
// RATED обходиться без урахування напрямку; з рівноцінних найкоротших шляхів повертаємо один.
MATCH (first:User {userId: 1}), (second:User {userId: 46})
MATCH path = shortestPath((first)-[:RATED*]-(second))
RETURN first.userId AS fromUser, second.userId AS toUser, length(path) AS hops,
       [node IN nodes(path) |
         CASE WHEN node:User
           THEN {kind: 'User', userId: node.userId}
           ELSE {kind: 'Movie', movieId: node.movieId, title: node.title}
         END
       ] AS route;
