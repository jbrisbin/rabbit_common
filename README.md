# Rebar-friendly fork of Rabbit common

This is a fork of the rabbit_common dependency, which is needed by the 
[official RabbitMQ/AMQP Erlang client](https://github.com/rabbitmq/rabbitmq-erlang-client). 

It's meant to be included in your rebar projects in your rebar.config file:

		{deps, [
			{rabbit_common, ".*", {git, "git://github.com/jbrisbin/rabbit_common.git", "rabbitmq_2.6.1"}}
		]}.

This is simply a re-packaging of the rabbit_common AMQP client dependency, which is licensed under the MPL:

		This package, the RabbitMQ server is licensed under the MPL. For the
		MPL, please see LICENSE-MPL-RabbitMQ.

		If you have any questions regarding licensing, please contact us at
		info@rabbitmq.com.
