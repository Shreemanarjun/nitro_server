/// Class-based route controllers: group related routes behind a shared prefix
/// and middleware, the nitro_server analogue of a Spring `@RestController`.
library;

import 'dart:async';

import 'context.dart';
import 'route_group.dart';

/// A class that bundles related routes under a shared [prefix] and
/// [middleware] — the organizing unit a Spring `@RestController` gives you,
/// but with no annotations and no code generation (so it works under AOT and
/// needs no build step). Subclass it, declare routes in [register] using the
/// usual verb shorthands, and mount it with [NitroServer.mount]:
///
/// ```dart
/// class UserController extends Controller {
///   UserController(this._db) : super(prefix: '/users', middleware: [cors()]);
///   final Db _db;
///
///   @override
///   Future<void> register(RouteGroup on) async {
///     await on.get('/', list);        // GET    /users
///     await on.get('/:id', getOne);   // GET    /users/:id
///     await on.post('/', create);     // POST   /users
///   }
///
///   Future<ResponseContext> list(RequestContext c) async =>
///       ResponseContext.jsonBody(await _db.all());
///   Future<ResponseContext> getOne(RequestContext c) async =>
///       ResponseContext.jsonBody(await _db.find(c.param('id')));
///   Future<ResponseContext> create(RequestContext c) async =>
///       ResponseContext.jsonBody(await _db.add(c.json()), status: 201);
/// }
///
/// await server.mount(UserController(db));
/// ```
///
/// The controller's handlers are ordinary methods, so they share the
/// controller's fields (injected dependencies, config) — the DX win over free
/// functions. [register] receives a [RouteGroup] already scoped to [prefix]
/// and [middleware]; nest more groups off it if needed.
abstract class Controller {
  /// [prefix] is the shared path for every route (e.g. `/users`); `/` (the
  /// default) mounts at the root. [middleware] wraps every route in this
  /// controller, inside the server-global chain and outside any per-route
  /// middleware (see [RouteGroup.use]).
  const Controller({this.prefix = '/', this.middleware = const []});

  /// Shared path prefix for every route this controller registers.
  final String prefix;

  /// Middleware applied to every route in this controller.
  final List<Middleware> middleware;

  /// Declares this controller's routes on [on] — a [RouteGroup] already scoped
  /// to [prefix] and [middleware]. Call the verb shorthands (`on.get`,
  /// `on.post`, …); `await` them so registration completes before [mount]
  /// returns.
  FutureOr<void> register(RouteGroup on);
}
