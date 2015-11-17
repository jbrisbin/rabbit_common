# Rebar-friendly fork of Rabbit common

This is a fork of the rabbit_common dependency, which is needed by the
[official RabbitMQ/AMQP Erlang client](https://github.com/rabbitmq/rabbitmq-erlang-client).

It's meant to be included in your rebar projects in your rebar.config file:

    {deps, [
      {rabbit_common, ".*", {git, "git://github.com/jbrisbin/rabbit_common.git", "rabbitmq-3.5.6-community"}}
    ]}.

The "master" branch of this port is a simple re-packaging of the rabbit_common AMQP client dependency.

### License

This package, just like the the RabbitMQ server, is licensed under the MPL. For the MPL, please see LICENSE-MPL-RabbitMQ.
