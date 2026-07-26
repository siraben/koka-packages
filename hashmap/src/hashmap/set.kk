/* A persistent hash set.

   A thin wrapper over `hashmap/map` with `()` values, so it inherits the same
   representation, iteration order (ascending hash), complexity, and sharing
   behaviour.  See that module for the details; they are not repeated here.

   The set is a distinct type rather than an alias for `hmap<k,()>`: an alias
   would make every set operation overload-ambiguous with the map operation of
   the same name.
*/
module hashmap/set

import hashmap/map

pub value struct hset<k>( entries : hmap<k,()> )

pub fun empty() : hset<k>
  Hset(map/empty())

pub fun is-empty( s : hset<k> ) : bool
  s.entries.map/is-empty

pub fun size( s : hset<k> ) : int
  s.entries.map/size

pub fun insert( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  Hset(s.entries.map/insert(key, ()))

pub fun remove( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  Hset(s.entries.map/remove(key))

pub fun member( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  s.entries.map/contains(key)

// Elements in iteration order (ascending hash).
pub fun list( s : hset<k> ) : div list<k>
  s.entries.map/keys

pub fun hset( xs : list<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  xs.foldl(empty(), fn(acc, x) acc.insert(x))

pub fun union( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  b.list.foldl(a, fn(acc, x) acc.insert(x))

pub fun intersect( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  a.list.foldl(empty(), fn(acc, x) if b.member(x) then acc.insert(x) else acc)

pub fun difference( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  a.list.foldl(empty(), fn(acc, x) if b.member(x) then acc else acc.insert(x))

pub fun subset( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  a.list.all(fn(x) b.member(x))

pub fun (==)( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  a.size == b.size && subset(a, b)

pub fun show( s : hset<k>, ?show : k -> string ) : div string
  "{" ++ s.list.map(show).join(", ") ++ "}"
