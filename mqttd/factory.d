module mqttd.factory;


import mqttd.message;
import cerealed.decerealiser;
import std.stdio;


struct MqttFactory {
    static this() {
        _cereal = new Decerealiser;
    }

    static MqttMessage create(in ubyte[] bytes) {
        _cereal.reset(bytes);
        auto fixedHeader = _cereal.value!MqttFixedHeader;
        if(fixedHeader.remaining < _cereal.bytes.length) {
            stderr.writeln("Wrong MQTT remaining size ", cast(int)fixedHeader.remaining,
                           ". Real remaining size: ", _cereal.bytes.length);
        }

        const mqttSize = fixedHeader.remaining + MqttFixedHeader.SIZE;
        if(mqttSize != bytes.length) {
            stderr.writeln("Malformed packet. Actual size: ", bytes.length,
                           ". Advertised size: ", mqttSize, " (r ", fixedHeader.remaining ,")");
            stderr.writeln("Packet:");
            stderr.writefln("%(0x%x %)", bytes);
            return null;
        }

        _cereal.reset(); //so the messages created below can re-read the header

        switch(fixedHeader.type) with(MqttType) {
        case CONNECT:
            return _cereal.value!MqttConnect(fixedHeader);
        case CONNACK:
            return _cereal.value!MqttConnack;
        case PUBLISH:
            return _cereal.value!MqttPublish(fixedHeader);
        case SUBSCRIBE:
            if(fixedHeader.qos != 1) {
                stderr.writeln("SUBSCRIBE message with qos ", fixedHeader.qos, ", should be 1");
            }
            return _cereal.value!MqttSubscribe(fixedHeader);
        case SUBACK:
            return _cereal.value!MqttSuback(fixedHeader);
        case UNSUBSCRIBE:
            return _cereal.value!MqttUnsubscribe(fixedHeader);
        case UNSUBACK:
            return _cereal.value!MqttUnsuback(fixedHeader);
        case PINGREQ:
            return new MqttPingReq();
        case PINGRESP:
            return new MqttPingResp();
        case DISCONNECT:
            return new MqttDisconnect();
        default:
            stderr.writeln("Unknown MQTT message type: ", fixedHeader.type);
            return null;
        }
    }

private:

    static Decerealiser _cereal;
}
