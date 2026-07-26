/* A minimal router: method, literal path, and simple `:name` parameters.

   Enough for the reference service's five routes and nothing more.  There is
   no middleware stack, no route groups, no wildcards and no regular
   expressions.

   Matching is first-declared-wins over the route list.  A path that matches no
   route is 404; a path that matches a route's *pattern* but not its method is
   405 with an `Allow` header listing the methods that would have worked --
   which is why the router, not the handler, decides that.
*/
module http/router

import bytes/bytes
import http/message

// A matched route's path parameters, in declaration order.
pub alias params = list<(string, string)>

pub fun param( ps : params, name : string ) : maybe<string>
  ps.lookup(fn(k) k == name)

pub struct route<e>
  method  : string
  // e.g. "/items/:id"
  pattern : string
  run     : (request, params) -> e response

pub fun route( method : string, pattern : string,
               run : (request, params) -> e response ) : route<e>
  Route(method.to-upper, pattern, run)

pub type match-result<e>
  Matched( run : (request, params) -> e response, params : params )
  NoSuchPath
  // The path exists but not for this method; these are the methods that work.
  WrongMethod( allowed : list<string> )

// Find the first route whose method and pattern both match.
//
// The captured parameters are kept alongside the route rather than recovered by
// matching a second time: a `filter` on `is-just` followed by a `match` that
// has to handle the `Nothing` it just excluded is a branch no test can reach,
// and the compiler cannot tell it is dead either.
pub fun route-match( routes : list<route<e>>, verb : string, path : string ) : match-result<e>
  val m = verb.to-upper
  val path-matches = routes.filter-map fn(r)
    match match-pattern(r.pattern, path)
      Just(ps) -> Just((r, ps))
      Nothing  -> Nothing
  match path-matches.filter(fn(rp) rp.fst.method == m)
    Cons((r, ps), _) -> Matched(r.run, ps)
    Nil ->
      if path-matches.is-nil then NoSuchPath
      else WrongMethod(path-matches.map(fn(rp) rp.fst.method).distinct-strings)

// Match a pattern against a path, returning the captured parameters.
//
// Segments are compared literally except for `:name`, which captures one
// segment.  An empty capture does not match, so `/items/` does not satisfy
// `/items/:id`.
pub fun match-pattern( pattern : string, path : string ) : maybe<params>
  walk(pattern.split("/"), path.split("/"), [])

// Matching on the two lists separately (rather than on a tuple of them) is
// what lets the termination checker see that both shrink, which keeps the
// router `total` -- and that in turn keeps `dispatch`'s effect row exactly the
// routes' row, with no stray `div` to reconcile at the call site.
fun walk( pat : list<string>, seg : list<string>, acc : params ) : maybe<params>
  match pat
    Nil -> match seg
             Nil -> Just(acc.reverse)
             _   -> Nothing
    Cons(p, ps) ->
      match seg
        Nil -> Nothing
        Cons(s, ss) ->
          if p.starts-with(":").bool then
            if s.is-empty then Nothing
            else walk(ps, ss, Cons((p.drop-first, s), acc))
          elif p == s then walk(ps, ss, acc)
          else Nothing

fun drop-first( s : string ) : string
  s.list.drop(1).string

fun distinct-strings( xs : list<string> ) : list<string>
  xs.foldl([], fn(acc, x) if acc.any(fn(y) y == x) then acc else acc ++ [x])

// Dispatch a request, producing the 404 and 405 responses itself.
pub fun dispatch( routes : list<route<e>>, r : request,
                  not-found : (request) -> e response = default-not-found,
                  wrong-method : (request, list<string>) -> e response = default-wrong-method
                ) : e response
  match route-match(routes, r.method, r.path)
    Matched(h, ps)     -> h(r, ps)
    NoSuchPath         -> not-found(r)
    WrongMethod(allow) -> wrong-method(r, allow)

pub fun default-not-found( _r : request ) : e response
  json-response(404, "{\"error\":\"not found\"}")

pub fun default-wrong-method( _r : request, allowed : list<string> ) : e response
  response(405, bytes("{\"error\":\"method not allowed\"}"),
           [("content-type", "application/json"), ("allow", allowed.join(", "))])
