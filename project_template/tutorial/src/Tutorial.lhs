What Are Snaplets?
==================

Snaplets allow you to build web applications out of composable parts. This
lets you to build self-contained pieces of functionality and glue them
together to make your overall application. Here are some of the things
provided by the snaplet infrastructure:

  - Infrastructure for application state/environment

  - Snaplet initialization, reload, and cleanup

  - Management of filesystem data and automatic snaplet installation

  - Unified config file infrastructure


Snaplet Overview
================

A snaplet is a web application, and web applications are snaplets. This means
that using snaplets and writing snaplets are almost the same thing.

The heart of the snaplets infrastructure is state management. Most nontrivial
pieces of a web app need some kind of state or environment data. Components
that do not need any kind of state or environment are probably more
appropriate as a standalone library than as a snaplet.

Before we continue, we must clarify an important point. The Snap web server
processes each request in its own green thread. This means that each request
will receive a separate copy of the state defined by your application and
snaplets, and modifications to that state only affect the local thread that
generates a single response. From now on, when we talk about state this is
what we are talking about. If you need global application state, you have to
use a thread-safe construct such as an MVar or IORef.

First we need to get imports out of the way.

> {-# LANGUAGE TemplateHaskell #-}
> {-# LANGUAGE OverloadedStrings #-}
> 
> module Main where
> 
> import           Control.Applicative
> import           Data.IORef
> import           Control.Monad.State
> import           Data.Lens.Template
> import           Data.Maybe
> import qualified Data.ByteString.Char8 as B
> import           Snap.Core
> import           Snap.Http.Server
> import           Snap.Snaplet
> import           Snap.Snaplet.Heist
> import           Part2

We start our application by defining a data structure to hold the state. This
data structure includes the state of any snaplets (wrapped in a Snaplet) we
want to use as well as any other state we might want.

> data App = App
>     { _heist       :: Snaplet (Heist App)
>     , _foo         :: Snaplet Foo
>     , _bar         :: Snaplet Bar
>     , _companyName :: IORef B.ByteString
>     }
>
> makeLenses [''App]

The field names begin with an underscore because of some more complicated
things going on under the hood. However, all you need to know right now is
that you should prefix things with an underscore and then call makeLenses.
This lets you use the names without an underscore in the rest of your
application.

The next thing we need to do is define an initializer.

> app :: SnapletInit App App
> app = makeSnaplet "myapp" "My example application" Nothing $ do
>     hs <- nestSnaplet "heist" heist $ heistInit "templates"
>     fs <- nestSnaplet "foo" foo $ fooInit
>     bs <- nestSnaplet "" bar $ nameSnaplet "baz" $ barInit foo
>     addRoutes [ ("/hello", writeText "hello world")
>               , ("/fooname", with foo namePage)
>               , ("/barname", with bar namePage)
>               , ("/company", companyHandler)
>               ]
>     wrapHandlers (<|> heistServe)
>     mvar <- liftIO $ newIORef "fooCorp"
>     return $ App hs fs bs mvar

For now don't worry about the two type parameters to SnapletInit. We'll
discuss them in more detail later. The basic idea here is that to initialize an
application, we first initialize each of the snaplets, add some routes, run a
function wrapping all the routes, and return the resulting state data
structure. This example demonstrates the use of a few of the most common
snaplet functions.

nestSnaplet
-----------
   
All calls to child snaplet initializer functions must be wrapped in a call to
nestSnaplet. The first parameter is a URL path segment that is used to prefix
all routes defined by the snaplet. This lets you ensure that there will be no
problems with duplicate routes defined in different snaplets. If the foo
snaplet defines a route /foopage, then in the above example, that page will be
available at /foo/foopage. Sometimes though, you might want a snaplet's routes
to be available at the top level. To do that, just pass an empty string to
nestSnaplet as shown above with the bar snaplet.

The second parameter to nestSnaplet is the lens to the snaplet you're nesting.
In order to place a piece into the puzzle, you need to know where it goes.

In our example above, the bar snaplet does something that needs to know about
the foo snaplet. Maybe foo is a database snaplet and bar wants to store or
read something.  In order to make that happen, it needs to have a "handle" to
the snaplet. Our handles are whatever field names we used in the App data
structure minus the initial underscore character. They are automatically
generated by the makeLenses function. For now it's sufficient to think of them
as a getter and a setter combined (to use an OO metaphor).

nameSnaplet
-----------

Snaplets usually define a default name used to identify the snaplet. This name
is used for the snaplet's directory in the filesystem. If you don't want to use
the default name, you can override it with the nameSnaplet function. Also, if
you want to have two instances of the same snaplet, then you will need to use
nameSnaplet to give at least one of them a unique name.

addRoutes
---------

The addRoutes function is how an application (or snaplet) defines its routes.
Under the hood the snaplet infrastructure merges all the routes from all
snaplets, prepends prefixes from nestSnaplet calls, and passes the list to
Snap's
[route](http://hackage.haskell.org/packages/archive/snap-core/0.5.1.4/doc/html/Snap-Types.html#v:route)
function. This gives us the first introduction to Handler, the other main data
type defined by the snaplet infrastructure. During initialization, snaplets use
the Initializer monad. During runtime, snaplets use the Handler monad. We'll
discuss Handler in more detail later. If you're familiar with Snap's old
extension system, you can think of it as roughly equivalent to the Application
monad. It has a MonadState instance that lets you access and modify the current
snaplet's state, and a MonadSnap instance providing the request-processing
functions defined in Snap.Types.

wrapHandlers
------------

wrapHandlers allows you to apply an arbitrary Handler transformation to the
top-level handler. This is useful if you want to do some generic processing at
the beginning or end of every request. For instance, a session snaplet might
use it to touch a session activity token at the beginning of every request. It
could also be used to implement custom logging. The example above uses it to
define heistServe (provided by the Heist snaplet) as the default handler to be
tried if no other handler matched. This example is easy to understand, but
defining routes in this way gives O(n) time complexity, whereas routes defined
with addRoutes have O(log n) time complexity. In a real-world application you
would probably want to have ("", heistServe) in the list passed to addRoutes.

with
----

The last unfamiliar function in the example is 'with'. Here it accompanies a
call to the function namePage.  namePage is a simple example handler and looks
like this.

> namePage :: Handler b v ()
> namePage = do
>     mname <- getSnapletName
>     writeText $ fromMaybe "This shouldn't happen" mname

This function is a simple handler that gets the name of the current snaplet
and writes it into the response with the writeText function defined by the
snap-core project.  The type variables 'b' and 'v' indicate that this function
will work in any snaplet with any base application.  The 'with' function is
used to run namePage in the context of the snaplets foo and bar for the
corresponding routes.  

Working with state
------------------

"Handler b v" has a "MonadState v" instance.  This means that you can access
all your snaplet state through the get, put, gets, and modify functions that
are probably familiar from the state monad.  In our example application we
demonstrate this with companyHandler.

> companyHandler :: Handler App App ()
> companyHandler = method GET getter <|> method POST setter
>   where
>     getter = do
>         nameRef <- gets _companyName
>         name <- liftIO $ readIORef nameRef
>         writeBS name
>     setter = do
>         mname <- getParam "name"
>         nameRef <- gets _companyName
>         liftIO $ maybe (return ()) (writeIORef nameRef) mname
>         getter

If you set a GET request to /company, you'll get the string "fooCorp" back.
If you send a POST request, it will set the IORef held in the _companyName
field in the App data structure to the value of the "name" field.  Then it
calls the getter to return that value back to you so you can see it was
actually changed.  Again, remember that this change only persists across
requests because we used an IORef.  If _companyName was just a plain string
and we had used modify, the changed result would only be visible in the rest
of the processing for that request.

The Heist Snaplet
=================

The astute reader might ask why there is no "with heist" in front of the call
to heistServe.


> instance HasHeist App where heistLens = subSnaplet heist

> main :: IO ()
> main = serveSnaplet defaultConfig app


