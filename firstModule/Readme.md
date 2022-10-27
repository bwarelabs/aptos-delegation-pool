```sh
aptos move compile --named-addresses hello_blockchain=default

aptos move test --named-addresses hello_blockchain=default

aptos move publish --named-addresses hello_blockchain=default

aptos move run \
  --function-id 'default::message::set_message' \
  --args 'string:hello, blockchain'


https://fullnode.testnetnet.aptoslabs.com/v1/accounts/a345dbfb0c94416589721360f207dcc92ecfe4f06d8ddc1c286f569d59721e5a/resource/0xa345dbfb0c94416589721360f207dcc92ecfe4f06d8ddc1c286f569d59721e5a::message::MessageHolder

http://127.0.0.1:8080/v1/accounts/0xa345dbfb0c94416589721360f207dcc92ecfe4f06d8ddc1c286f569d59721e5a/events/0xa345dbfb0c94416589721360f207dcc92ecfe4f06d8ddc1c286f569d59721e5a::message::MessageHolder/message_change_events


move new <pkg_name>
move build
move test
```