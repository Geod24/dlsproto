/*******************************************************************************

    Client DLS Put v1 request handler.

    Copyright:
        Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module dlsproto.client.request.internal.Put;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.meta.types.Qualifiers;
import ocean.util.log.Logger;

/*******************************************************************************

    Module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("dlsproto.client.request.internal.Put");
}

/*******************************************************************************

    Put request implementation.

    Note that request structs act simply as namespaces for the collection of
    symbols required to implement a request. They are never instantiated and
    have no fields or non-static functions.

    The client expects several things to be present in a request struct:
        1. The static constants request_type and request_code
        2. The UserSpecifiedParams struct, containing all user-specified request
            setup (including a notifier)
        3. The Notifier delegate type
        4. Optionally, the Controller type (if the request can be controlled,
           after it has begun)
        5. The handler() function
        6. The all_finished_notifier() function

    The RequestCore mixin provides items 1 and 2.

*******************************************************************************/

public struct Put
{
    import dlsproto.common.Put;
    import dlsproto.client.request.Put;
    import dlsproto.common.RequestCodes;
    import swarm.neo.client.mixins.RequestCore;
    import swarm.neo.client.RequestHandlers : IRoundRobinConnIterator;
    import swarm.neo.request.Command;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    /***************************************************************************

        Data which the request needs while it is progress. An instance of this
        struct is stored per connection on which the request runs and is passed
        to the request handler.

    ***************************************************************************/

    private static struct SharedWorking
    {
        bool succeeded;
    }

    /***************************************************************************

        Request core. Mixes in the types `NotificationInfo`, `Notifier`,
        `Params`, `Context` plus the static constants `request_type` and
        `request_code`.

    ***************************************************************************/

    mixin RequestCore!(RequestType.RoundRobin, RequestCode.Put, 1, Args,
        SharedWorking, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            conns = round-robin getter for per-connection event dispatchers
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled

    ***************************************************************************/

    public static void handler ( IRoundRobinConnIterator conns,
        void[] context_blob )
    {
        auto context = Put.getContext(context_blob);
        context.shared_working.succeeded = false;

        round_robin: foreach (conn; conns)
        {
            try
            {
                // Send request info to node
                conn.send(
                    ( conn.Payload payload )
                    {
                        payload.add(Put.cmd.code);
                        payload.add(Put.cmd.ver);
                        payload.addArray(context.user_params.args.channel);
                        payload.add(context.user_params.args.timestamp);
                        payload.addArray(context.user_params.args.value);
                    }
                );

                // Receive status from node and exit the loop if OK
                auto supported = conn.receiveValue!(SupportedStatus)();
                if ( !Put.handleSupportedCodes(supported, context,
                    conn.remote_address) )
                {
                    context.shared_working.succeeded = false;
                }
                else
                {
                    auto status = conn.receiveValue!(StatusCode)();
                    switch ( status )
                    {
                        case RequestStatusCode.Put:
                            context.shared_working.succeeded = true;
                            break round_robin;

                        case RequestStatusCode.Error:
                            // The node returned an error code. Notify the user
                            // and try another connection.
                            Notification n;
                            n.node_error = NodeInfo(conn.remote_address);
                            Put.notify(context.user_params, n);
                            break;

                        default:
                            log.warn("Received unknown status code {} from node "
                                ~ "in response to Put request. Treating as "
                                ~ "Error.", status);
                            goto case RequestStatusCode.Error;
                    }
                }
            }
            catch ( IOError e )
            {
                // A connection error occurred. Notify the user and try another
                // connection.
                auto info = NodeExceptionInfo(conn.remote_address, e);

                Notification n;
                n.node_disconnected = info;
                Put.notify(context.user_params, n);
            }
        }
    }

    /***************************************************************************

        Request finished notifier. Called from Request.handlerFinished().

        Params:
            context_blob = untyped chunk of data containing the serialized
                context of the request which is finishing

    ***************************************************************************/

    public static void all_finished_notifier ( void[] context_blob )
    {
        auto context = Put.getContext(context_blob);

        // Final notification
        NoInfo info;
        Notification n;
        if ( context.shared_working.succeeded )
            n.success = info;
        else
            n.failure = info;
        Put.notify(context.user_params, n);
    }
}
