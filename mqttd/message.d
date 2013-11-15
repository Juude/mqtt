module mqttd.message;


import mqttd.server;
import cerealed;
import std.stdio;
import std.algorithm;

enum MqttType {
    RESERVED1   = 0,
    CONNECT     = 1,
    CONNACK     = 2,
    PUBLISH     = 3,
    PUBACK      = 4,
    PUBREC      = 5,
    PUBREL      = 6,
    PUBCOMP     = 7,
    SUBSCRIBE   = 8,
    SUBACK      = 9,
    UNSUBSCRIBE = 10,
    UNSUBACK    = 11,
    PINGREQ     = 12,
    PINGRESP    = 13,
    DISCONNECT  = 14,
    RESERVED2   = 15
}

struct MqttFixedHeader {
public:
    enum SIZE = 2;

    @Bits!4 MqttType type;
    @Bits!1 bool dup;
    @Bits!2 ubyte qos;
    @Bits!1 bool retain;
    @Bits!8 uint remaining;
    Decerealiser cereal;

    void accept(Cereal cereal) {
        //custom serialisation needed due to remaining size field
        cereal.grainMember!"type"(this);
        cereal.grainMember!"dup"(this);
        cereal.grainMember!"qos"(this);
        cereal.grainMember!"retain"(this);
        final switch(cereal.type) {
        case Cereal.Type.Write:
            setRemainingSize(cereal);
            break;

        case Cereal.Type.Read:
            remaining = getRemainingSize(cereal);
            break;
        }
    }

private:

    uint getRemainingSize(Cereal cereal) {
        //algorithm straight from the MQTT spec
        int multiplier = 1;
        uint value = 0;
        ubyte digit;
        do {
            cereal.grain(digit);
            value += (digit & 127) * multiplier;
            multiplier *= 128;
        } while((digit & 128) != 0);

        return value;
    }

    void setRemainingSize(Cereal cereal) const {
        //algorithm straight from the MQTT spec
        ubyte[] digits;
        uint x = remaining;
        do {
            ubyte digit = x % 128;
            x /= 128;
            if(x > 0) {
                digit = digit | 0x80;
            }
            digits ~= digit;
        } while(x > 0);
        foreach(b; digits) {
            cereal.grain(b);
        }
    }
}

class MqttMessage {
    void handle(MqttServer server, MqttConnection connection) const {}
}

class MqttConnect: MqttMessage {
public:

    this(Decerealiser cereal) {
        accept(cereal);
    }

    void accept(Cereal cereal) {
        cereal.grainMember!"protoName"(this);
        cereal.grainMember!"protoVersion"(this);
        cereal.grainMember!"hasUserName"(this);
        cereal.grainMember!"hasPassword"(this);
        cereal.grainMember!"hasWillRetain"(this);
        cereal.grainMember!"willQos"(this);
        cereal.grainMember!"hasWill"(this);
        cereal.grainMember!"hasClear"(this);
        cereal.grainMember!"reserved"(this);
        cereal.grainMember!"keepAlive"(this);
        cereal.grainMember!"clientId"(this);
        if(hasWill) cereal.grainMember!"willTopic"(this);
        if(hasWill) cereal.grainMember!"willMessage"(this);
        if(hasUserName) cereal.grainMember!"userName"(this);
        if(hasPassword) cereal.grainMember!"password"(this);
    }

    @property bool isBadClientId() const { return clientId.length < 1 || clientId.length > 23; }

    string protoName;
    ubyte protoVersion;
    @Bits!1 bool hasUserName;
    @Bits!1 bool hasPassword;
    @Bits!1 bool hasWillRetain;
    @Bits!2 ubyte willQos;
    @Bits!1 bool hasWill;
    @Bits!1 bool hasClear;
    @Bits!1 bool reserved;
    ushort keepAlive;
    string clientId;
    string willTopic;
    string willMessage;
    string userName;
    string password;
}

class MqttConnack: MqttMessage {

    enum Code: byte {
        ACCEPTED = 0,
        BAD_VERSION = 1,
        BAD_ID = 2,
        SERVER_UNAVAILABLE = 3,
        BAD_USER_OR_PWD = 4,
        NO_AUTH = 5,
    }

    this(Code code) {
        this.code = code;
    }

    this(Decerealiser cereal) {
        accept(cereal);
    }

    void accept(Cereal cereal) {
        auto header = MqttFixedHeader(MqttType.CONNACK, false, 0, false, 2);
        cereal.grain(header);
        cereal.grain(reserved);
        cereal.grain(code);
    }

    ubyte reserved;
    Code code;
}


class MqttPublish: MqttMessage {
public:
    this(MqttFixedHeader header, Decerealiser cereal) {
        topic = cereal.value!string;
        auto payloadLen = header.remaining - (topic.length + 2);
        if(header.qos > 0) {
            if(header.remaining < 7) {
                stderr.writeln("Error: PUBLISH message with QOS but no message ID");
            } else {
                msgId = cereal.value!ushort;
                payloadLen -= 2;
            }
        }

        for(int i = 0; i < payloadLen; ++i) {
            payload ~= cereal.value!ubyte;
        }

        this.header = header;
    }

    this(in string topic, in ubyte[] payload, ushort msgId = 0) {
        this(false, 0, false, topic, payload, msgId);
    }

    this(in bool dup, in ubyte qos, in bool retain, in string topic, in ubyte[] payload, in ushort msgId = 0) {
        const topicLen = cast(uint)topic.length + 2; //2 for length
        auto remaining = qos ? topicLen + 2 /*msgId*/ : topicLen;
        remaining += payload.length;
        this.topic = topic;
        this.payload = payload;
        this.msgId = msgId;
        this.header = MqttFixedHeader(MqttType.PUBLISH, dup, qos, retain, remaining);
    }

    const(ubyte[]) encode() {
        auto cereal = new Cerealiser;
        cereal ~= header;
        cereal ~= topic;
        if(header.qos) {
            cereal ~= msgId;
        }

        return cereal.bytes ~ cast(ubyte[])payload;
    }

    override void handle(MqttServer server, MqttConnection connection) const {
        server.publish(topic, payload);
    }

    MqttFixedHeader header;
    string topic;
    const(ubyte)[] payload;
    ushort msgId;
}


class MqttSubscribe: MqttMessage {
public:
    this(Decerealiser cereal) {
        msgId = cereal.value!ushort;
        while(cereal.bytes.length) {
            topics ~= Topic(cereal.value!string, cereal.value!ubyte);
        }
    }

    override void handle(MqttServer server, MqttConnection connection) const {
        server.subscribe(connection, msgId, topics);
    }

    static struct Topic {
        string topic;
        ubyte qos;
    }

    Topic[] topics;
    ushort msgId;
}

class MqttSuback: MqttMessage {
public:

    this(in ushort msgId, in ubyte[] qos) {
        this.msgId = msgId;
        this.qos = qos.dup;
    }

    this(Decerealiser cereal) {
        msgId = cereal.value!ushort();
        qos = cereal.bytes.dup;
    }

    const(ubyte[]) encode() const {
        auto cereal = new Cerealiser();
        cereal ~= MqttFixedHeader(MqttType.SUBACK, false, 0, false, cast(uint)qos.length + 2);
        cereal ~= msgId;
        foreach(q; qos) cereal ~= q;
        return cereal.bytes;
    }

    ushort msgId;
    ubyte[] qos;
}


class MqttDisconnect: MqttMessage {
    override void handle(MqttServer server, MqttConnection connection) const {
        connection.disconnect();
    }
}

class MqttPingReq: MqttMessage {
    override void handle(MqttServer server, MqttConnection connection) const {
        server.ping(connection);
    }
}

class MqttPingResp: MqttMessage {
    const(ubyte[]) encode() const {
        return [0xd0, 0x00];
    }
}