# Copyright (c) 2013, Kenton Varda <temporal@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

@0xa184c7885cdaf2a1;
# This file defines the "network-specific parameters" in rpc.capnp to support a network consisting
# of two vats.  Each of these vats may in fact be in communication with other vats, but any
# capabilities they forward must be proxied.  Thus, to each end of the connection, all capabilities
# received from the other end appear to live in a single vat.
#
# Two notable use cases for this model include:
# - Regular client-server communications, where a remote client machine (perhaps living on an end
#   user's personal device) connects to a server.  The server may be part of a cluster, and may
#   call on other servers in the cluster to help service the user's request.  It may even obtain
#   capabilities from these other servers which it passes on to the user.  To simplify network
#   common traversal problems (e.g. if the user is behind a firewall), it is probably desirable to
#   multiplex all communications between the server cluster and the client over the original
#   connection rather than form new ones.  This connection should use the two-party protocol, as
#   the client has no interest in knowing about additional servers.
# - Applications running in a sandbox.  A supervisor process may execute a confined application
#   such that all of the confined app's communications with the outside world must pass through
#   the supervisor.  In this case, the connection between the confined app and the supervisor might
#   as well use the two-party protocol, because the confined app is intentionally prevented from
#   talking to any other vat anyway.  Any external resources will be proxied through the supervisor,
#   and so to the contained app will appear as if they were hosted by the supervisor itself.
#
# Since there are only two vats in this network, there is never a need for three-way introductions,
# so level 3 is free.  Moreover, because it is never necessary to form new connections, the
# two-party protocol can be used easily anywhere where a two-way byte stream exists, without regard
# to where that byte stream goes or how it was initiated.  This makes the two-party runtime library
# highly reusable.
#
# Joins (level 4) _could_ be needed in cases where one or both vats are participating in other
# networks that use joins.  For instance, if Alice and Bob are speaking through the two-party
# protocol, and Bob is also participating on another network, Bob may send Alice two or more
# proxied capabilities which, unbeknownst to Bob at the time, are in fact pointing at the same
# remote object.  Alice may then request to join these capabilities, at which point Bob will have
# to forward the join to the other network.  Note, however, that if Alice is _not_ participating on
# any other network, then Alice will never need to _receive_ a Join, because Alice would always
# know when two locally-hosted capabilities are the same and would never export a redundant alias
# to Bob.  So, Alice can respond to all incoming joins with an error, and only needs to implement
# outgoing joins if she herself desires to use this feature.  Also, outgoing joins are relatively
# easy to implement in this scenario.
#
# What all this means is that a level 4 implementation of the confined network is barely more
# complicated than a level 2 implementation.  However, such an implementation allows the "client"
# or "confined" app to access the server's/supervisor's network with equal functionality to any
# native participant.  In other words, an application which implements only the two-party protocol
# can be paired with a proxy app in order to participate in any network.
#
# So, when implementing Cap'n Proto in a new language, it makes sense to implement only the
# two-party protocol initially, and then pair applications with an appropriate proxy written in
# C++, rather than implement other parameterizations of the RPC protocol directly.

using Cxx = import "/capnp/c++.capnp";
$Cxx.namespace("capnp::rpc::twoparty");

enum Side {
  server @0;
  # The object lives on the "server" or "supervisor" end of the connection.  Only the
  # server/supervisor knows how to interpret the ref; to the client, it is opaque.
  #
  # Note that containers intending to implement strong confinement should rewrite SturdyRefs
  # received from the external network before passing them on to the confined app.  The confined
  # app thus does not ever receive the raw bits of the SturdyRef (which it could perhaps
  # maliciously leak), but instead receives only a thing that it can pass back to the container
  # later to restore the ref.  See:
  #     http://www.erights.org/elib/capability/dist-confine.html

  client @1;
  # The object lives on the "client" or "confined app" end of the connection.  Only the client
  # knows how to interpret the ref; to the server/supervisor, it is opaque.  Most clients do not
  # actually know how to persist capabilities at all, so use of this is unusual.
}

struct SturdyRefHostId {
  side @0 :Side;
}

struct ProvisionId {
  # Only used for joins, since three-way introductions never happen on a two-party network.

  joinId @0 :UInt32;
  # The ID from `JoinKeyPart`.
}

struct RecipientId {}
# Never used, because there are only two parties.

struct ThirdPartyCapId {}
# Never used, because there is no third party.

struct JoinKeyPart {
  # Joins in the two-party case are simplified by a few observations.
  #
  # First, on a two-party network, a Join only ever makes sense if the receiving end is also
  # connected to other networks.  A vat which is not connected to any other network can safely
  # reject all joins.
  #
  # Second, since a two-party connection bisects the network -- there can be no other connections
  # between the networks at either end of the connection -- if one part of a join crosses the
  # connection, then _all_ parts must cross it.  Therefore, a vat which is receiving a Join request
  # off some other network which needs to be forwarded across the two-party connection can
  # collect all the parts on its end and only forward them across the two-party connection when all
  # have been received.
  #
  # For example, imagine that Alice and Bob are vats connected over a two-party connection, and
  # each is also connected to other networks.  At some point, Alice receives one part of a Join
  # request off her network.  The request is addressed to a capability that Alice received from
  # Bob and is proxying to her other network.  Alice goes ahead and responds to the Join part as
  # if she hosted the capability locally (this is important so that if not all the Join parts end
  # up at Alice, the original sender can detect the failed Join without hanging).  As other parts
  # trickle in, Alice verifies that each part is addressed to a capability from Bob and continues
  # to respond to each one.  Once the complete set of join parts is received, Alice checks if they
  # were all for the exact same capability.  If so, she doesn't need to send anything to Bob at
  # all.  Otherwise, she collects the set of capabilities (from Bob) to which the join parts were
  # addressed and essentially initiates a _new_ Join request on those capabilities to Bob.  Alice
  # does not forward the Join parts she received herself, but essentially forwards the Join as a
  # whole.
  #
  # On Bob's end, since he knows that Alice will always send all parts of a Join together, he
  # simply waits until he's received them all, then performs a join on the respective capabilities
  # as if it had been requested locally.

  joinId @0 :UInt32;
  # A number identifying this join, chosen by the sender.  May be reused once `Finish` messages are
  # sent corresponding to all of the `Join` messages.

  partCount @1 :UInt16;
  # The number of capabilities to be joined.

  partNum @2 :UInt16;
  # Which part this request targets -- a number in the range [0, partCount).
}

struct JoinResult {
  joinId @0 :UInt32;
  # Matches `JoinKeyPart`.

  succeeded @1 :Bool;
  # All JoinResults in the set will have the same value for `succeeded`.  The receiver actually
  # implements the join by waiting for all the `JoinKeyParts` and then performing its own join on
  # them, then going back and answering all the join requests afterwards.

  cap @2 :AnyPointer;
  # One of the JoinResults will have a non-null `cap` which is the joined capability.
  #
  # TODO(cleanup):  Change `AnyPointer` to `Capability` when that is supported.
}
