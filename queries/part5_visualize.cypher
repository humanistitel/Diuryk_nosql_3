UNWIND [120, 5880, 1710, 1980, 3285] AS userId
CALL apoc.create.vNode(['ProjectedUser'], {caption:toString(userId)}) YIELD node
WITH collect({id:userId, node:node}) AS userNodes
UNWIND [[120,5880],[5880,1710],[120,1980],[1980,3285],[3285,1710]] AS pair
MATCH (a:User {userId:pair[0]})-[first:RATED]->(:Movie)<-[second:RATED]-(b:User {userId:pair[1]})
WHERE first.rating >= 4 AND second.rating >= 4
WITH userNodes, pair, count(*) AS shared
WITH head([u IN userNodes WHERE u.id=pair[0] | u.node]) AS a,
     head([u IN userNodes WHERE u.id=pair[1] | u.node]) AS b, shared
CALL apoc.create.vRelationship(a, 'SIMILAR', {weight:shared, cost:1.0/shared}, b) YIELD rel
RETURN a, rel, b;
