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

pub fun is-notempty( s : hset<k> ) : bool
  !s.is-empty

pub fun size( s : hset<k> ) : int
  s.entries.map/size

pub fun singleton( key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  empty().insert(key)

pub fun insert( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  Hset(s.entries.map/insert(key, ()))

pub fun remove( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  Hset(s.entries.map/remove(key))

pub fun member( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  s.entries.map/contains(key)

pub fun contains( s : hset<k>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  s.member(key)

// Elements in iteration order (ascending hash).
pub fun list( s : hset<k> ) : div list<k>
  s.entries.map/keys

pub fun hset( xs : list<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  xs.foldl(empty(), fn(acc, x) acc.insert(x))

pub fun union( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  b.fold(a, fn(acc, x) acc.insert(x))

pub fun intersect( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  a.fold(empty(), fn(acc, x) if b.member(x) then acc.insert(x) else acc)

pub fun difference( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  a.fold(empty(), fn(acc, x) if b.member(x) then acc else acc.insert(x))

pub fun symmetric-difference( a : hset<k>, b : hset<k>,
                              ?hash : k -> int, ?(==) : (k,k) -> bool )
                            : div hset<k>
  union(difference(a, b), difference(b, a))

pub fun subset( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  a.size <= b.size && a.list.all(fn(x) b.member(x))

pub fun proper-subset( a : hset<k>, b : hset<k>,
                       ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  a.size < b.size && a.subset(b)

pub fun superset( a : hset<k>, b : hset<k>,
                  ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  b.subset(a)

pub fun disjoint( a : hset<k>, b : hset<k>,
                  ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  val smaller = if a.size <= b.size then a else b
  val larger  = if a.size <= b.size then b else a
  smaller.list.all(fn(x) !larger.member(x))

pub fun foreach( s : hset<k>, action : (k) -> <div|e> () ) : <div|e> ()
  s.entries.map/foreach(fn(k, _v) action(k))

pub fun fold( s : hset<k>, init : a,
              f : (a, k) -> <div|e> a ) : <div|e> a
  s.entries.map/fold(init, fn(acc, k, _v) f(acc, k))

pub fun filter( s : hset<k>, pred : (k) -> bool,
                ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hset<k>
  s.fold(empty(), fn(acc, k) if pred(k) then acc.insert(k) else acc)

pub fun map( s : hset<k>, f : (k) -> k2,
             ?hash : k2 -> int, ?(==) : (k2,k2) -> bool ) : div hset<k2>
  s.fold(empty(), fn(acc, k) acc.insert(f(k)))

pub fun (==)( a : hset<k>, b : hset<k>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  a.size == b.size && subset(a, b)

pub fun show( s : hset<k>, ?show : k -> string ) : div string
  "{" ++ s.list.map(show).join(", ") ++ "}"
