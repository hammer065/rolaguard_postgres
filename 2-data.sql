-- Organizations
insert into public.organization (id, name, country, region) values (3, 'rolaguard_backend', '','');
insert into public.organization (id, name, country, region) values (4, 'Community Edition', '','');

-- User --
-- orchestrator -- (user.orchestrator/rolaguard_password)
insert into public.iot_user (username, email, full_name, password, organization_id, phone, active, deleted, blocked, first_login)
values ('user.orchestrator', 'user_orchestrator@your_host.com', 'Orchestrator User','$2b$12$vyJjHtINa1pMIbIamYo9xOgYKxQ20PvejNAYuQakh2ihBdX84Zqbm', 3, '+543435555555', true, false, false, true);
-- admin -- (admin/admin)
insert into public.iot_user (username, email, full_name, password, organization_id, phone, active, deleted, blocked, first_login)
values ('admin', 'admin@your_host.com', 'Preloaded Admin User','$2b$12$Z5vPo9nm9Lj2fszLoqrxFeSVwNBSWH9RLutm7btRl5MWdhPczUcsa', 4, '+543435555555', true, false, false, true);

-- User Roles --
insert into public.user_role(id, role_name)
values(1, 'Regular_User');
insert into public.user_role(id, role_name)
values(2, 'Admin_User');
insert into public.user_role(id, role_name)
values(9, 'System');

-- User / User Role --
-- system --
insert into public.user_to_user_role(user_id, user_role_id) values(1, 9);
-- admin --
insert into public.user_to_user_role(user_id, user_role_id) values(2, 2);

-- Collector Type --
insert into public.data_collector_type(id, "type", name) values (1, 'chirpstack_collector', 'Collector for ChirpStack.io v3 server');
insert into public.data_collector_type(id, "type", name) values (2, 'ttn_collector', 'Collector for The Things Network v2');
insert into public.data_collector_type(id, "type", name) values (3, 'ttn_v3_collector', 'Collector for The Things Network v3');
insert into public.data_collector_type(id, "type", name) values (4, 'chirpstack_v4_collector', 'Collector for ChirpStack.io v4 server');

-- TTN Region --
insert into public.ttn_region(id, "region", name) values (1, 'eu1', 'Europe 1 (eu1)');
insert into public.ttn_region(id, "region", name) values (2, 'nam1', 'North America 1 (nam1)');
insert into public.ttn_region(id, "region", name) values (3, 'au1', 'Australia 1 (au1)');

-- Alert type--
INSERT INTO public.alert_type (code,name,message,risk,description,parameters,technical_description,recommended_action,quarantine_timeout) VALUES 
('LAF-100','Device signal intensity below threshold','The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) has joined the network. Application: {join_eui} There are {number_of_devices} devices connected in this data collector. Message ID received {packet_id} on {packet_date} from gateway {gateway} (gateway name: {gw_name}, gw_vendor: {gw_vendor}. {rssi} Alert generated on {created_at}.','LOW','A packet from this device was received with an signal strength below the threshold set in the policy.','{"minimum_rssi": {"type": "Float", "default": -120, "maximum": 0, "minimum": -132, "description": "Minimum RSSI accepted, if the signal strength is lower an alert is emitted."}}','The signal strength of the device is too low, this can cause packet losing, duplicate packets and faster battery draining.','Try to get the device and the gateway closer. If this is not possible, consider add another gateway to increase the coverage.',3600)
,('LAF-001','Possible Join replay attack','DevNonce {dev_nonce} repeated for DevEUI {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}). Application: {join_eui} {app_name}. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','LOW','The DevNonce is a number used by the device at the moment of sending the Join Request (in OTAA operation mode) that assures the uniqueness and authenticity of that message. Since this number must be a random number between 0 and 65535, if it is repeated, it can be inferred that a third party is sending captured Join Request messages, previously sent by the device, in order to generate new sessions.','{}','DevNonces for each device should be random enough to not collide. If the same DevNonce was repeated in many messages, it can be inferred that a device is under a replay attack. This is, an attacker who captured a JoinRequest and is trying to send it again to the gateway in order to generate new sessions in the network server.','Check how DevNonces are generated: the function that generates them should be implemented using a random library. Moreover, you have to make sure that the server checks for historic DevNonces (they should be persisted in DB), in order not to accept an old valid JoinRequest previously sent by the device and thus generate a new session.',420)
,('LAF-500','Minor anomaly in device message','Received message from device {dev_eui} with address {dev_addr} (device name: {dev_name}, device vendor: {dev_vendor}) that presents an abnormal variable . Application: {join_eui} {app_name}. {specific_message}Current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','INFO','One variable of a received packet presents an abnormal value.','{}','The value of one of the analyzed variables is abnormal. This behaviour could be generated by several reasons, and is not enought to conclude that the packet was generated by an attacker. If more abnormal values are detected, a LAF-503 is emited.','Keep track of the messages sent by this device and check wether the traffic and its data is normal.',0)
,('LAF-002','Devices sharing the same DevAddr','DevAddr {dev_addr} had previous DevEUI {old_dev_eui}. Application: {join_eui} {app_name}. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','INFO','Two different devices might have been assigned the same DevAddr. This is not a security threat, but it should not happen since the lorawan server would not be able to distinguish by which device a message is generated.','{}','','If the device is over the air activated (OTAA): Check logic used to assign DevAddrs, and make sure that the server does not assign the same DevAddr to different devices. If the device is activated by personalization (ABP): Check the DevAddr configured in the firmware of the device is unique in the lorawan network.',3600)
,('LAF-011','Device not re-generating session keys','DevAddr {dev_addr} with DevEUI {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) counter was reset. Previous counter was {counter} and received {new_counter}. This device is not rejoining after counter overflow. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','HIGH','If the counter was reset (came back to 0), the DevAddr is kept the same, and no previous Join was detected, it may imply that the device is not going through a re-join process when its counter is overflowed (from 65535 to 0). ','{}','If sessions keys are not renewed, the device is exposed to eavesdropping attacks.','Force the device to start a Join process when its counter is overflowed.',0)
,('LAF-101','Device losing many packets','The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) has joined the network. Application: {join_eui} There are {number_of_devices} devices connected in this data collector. Message ID received {packet_id} on {packet_date} from gateway {gateway} (gateway name: {gw_name}, gw_vendor: {gw_vendor}. {packets_lost} Alert generated on {created_at}.','LOW','The device is losing more packets than the threshold set in the policy.','{"max_lost_packets": {"type": "Float", "default": 360, "maximum": 10000000, "minimum": 1, "description": "Maximum number of time lossing packets, if packets are lost for a period longer than this an alert is emitted."}}','There is a problem in the link, many packets of this devices are lossed.','This could be caused by a low signal strength. Try to get the device and the gateway closer. If this is not possible, consider add another gateway to increase the coverage.',3600)
,('LAF-400','New device','The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) has joined the network. Application: {join_eui} {app_name} There are {number_of_devices} devices connected in this data collector. Message ID received {packet_id} on {packet_date} from gateway {gateway} (gateway name: {gw_name}, gw_vendor: {gw_vendor}.
Alert generated on {created_at}.','INFO','A new device was detected in the network.','{}','This was determined by having detected a device with an unknown DevEui interacting with the network server.','Check if device belongs to your LoRaWAN network.',0)
,('LAF-501','Anomaly in Join Requests frequency','Change of frequency for JoinRequest messages for device with DevEUI  {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}). Application: {join_eui} {app_name}. Current message {packet_id} received on {packet_date} from gateway ID {gateway} gateway name: {gw_name}, gateway vendor: {gw_vendor}). Delta JR timestamp {delta} seconds, while the expected value is {median}.
Alert generated on {created_at}.','MEDIUM','It was detected an anomaly in the time frequency between Join Request messages of the device.','{"jr_tdiff_sensitivity":{"type" : "Float", "default" : 0.05, "maximum": 1.0, "minimum" : 0.0, "description" : "Minimum probability to consider the time between join requests normal. The time is analyzed in a logarithmic scale given that the time between join request messages has greater variations that data messages."}}','Received a Join Request message with a time frequency different that the device used to have for previous Join Requests received. This may be caused by an attacker trying to generate new sessions in the network server or trying to perform a join replay attack.','Check if device has re-joined at the time the alert was triggered. Otherwise, try to check if Join Requests received are legit or were sent by an attacker.',0)
,('LAF-503','Anomaly in device message','Received message from device {dev_eui} with address {dev_addr} (device name: {dev_name}, device vendor: {dev_vendor}) that presents abnormal metadata . Application: {join_eui} {app_name}. Message ID received {packet_id} on {packet_date} from gateway {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}). 
Alert generated on {created_at}','HIGH','Some variables of a received packet present abnormal values.','{"rssi_sensitivity":{"type" : "Float", "description" : "Minimum probability to consider the RSSI of a message normal", "default":0.005, "maximum":1.0, "minimum":0.000001},
"size_sensitivity":{"type" : "Float", "description" : "Minimum probability to consider the data size of a message normal", "default":0.005, "maximum":1.0, "minimum":0.000001},
"tdiff_sensitivity":{"type" : "Float", "description" : "Minimum probability to consider the time difference between messages of a device normal", "default":0.9, "maximum":1.0, "minimum":0.000001},
"cdiff_sensitivity":{"type" : "Float", "description" : "Minimum probability to consider the count difference between messages of a device normal", "default":0.005, "maximum":1.0, "minimum":0.00001},
"max_suspicious":{"type" : "Integer", "description" : "Minimum number of variables consider abnormal to emit an alert (LAF-503)", "default":3, "maximum":4, "minimum":2},
"grace_period":{"type" : "Integer", "description" : "Number of days with erratic behaviour before quarantine a device. An small number could generate quarantine on profilable devices, a big number could generate some false positive alerts before quarantine.", "default":10, "maximum":60, "minimum":1}}','The signal power, size of data, time between packets and counter behaviour are abnormal. This could indicate that the packet was generated by an attacker.','Keep track of the packets sent by this device and check wether the traffic and its data is normal.',0)
,('LAF-601','Issue manually marked as solved','Device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) removed from quarantine by the user {user_id} on {date}.','INFO','An issue has been solved','{}','An issue was marked as solved by the user','',0)
,('LAF-006','Possible ABP device','DevAddr {dev_addr} with DevEUI {dev_eui} counter was reset (device name: {dev_name}, device vendor: {dev_vendor}). Previous counter was {counter} and received {new_counter}. Application: {join_eui} {app_name}. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway}, gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','HIGH','If the counter was reset (came back to 0), the DevAddr is kept the same, and no previous Join process was detected, may imply that the device is Activated By Personalization (ABP), which is discouraged for security reasons.','{}','ABP devices implies that session keys are never changed in the whole lifecycle of the device. A device that does not change its session keys is prone to different attacks such as eaveasdrop or replay.','All activated by personalization (ABP) devices should be replaced for over the air activated (OTAA) devices if possible.',1209600)
,('LAF-401','Device connection lost','The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) has not send packets for a long period of time.  Application: {join_eui} {app_name}. There are {number_of_devices} devices connected in this data collector.
Alert generated on {created_at}.','LOW','A device has not send packets for a long period of time. It might be disconnected.','{"disconnection_sensitivity": {"type": "Float", "default":0.05, "maximum":1.0, "minimum":0.00001, "description": "Used when deciding whether to mark a device as disconnected or not. A device will become disconnected when the inactivity time becomes greater than (1/disconnection_sensitivity) times it usual period between up packages"}}','This was determined by having detected a device with an unknown footprint interacting with the network server.','Check why the device has stopped sending packets.',0)
,('LAF-402','New gateway found','The gateway {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}) has joined the network. Message ID received {packet_id} on {packet_date}.
Alert generated on {created_at}.','INFO','A new gateway was detected in the network.','{}','This was determined by having detected a gateway with an unknown identifier code interacting with the network server.','Check if gateway belongs to your LoRaWAN network.',0)
,('LAF-403','Gateway connection lost','The gateway {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}) has not send packets for a long period of time.
Alert generated on {created_at}.','LOW','A gateway has not send packets for a long period of time. It might be disconnected.','{"disconnection_sensitivity": {"type": "Float", "default":0.05, "maximum":1.0, "minimum":0.00001, "description": "Used when deciding whether to mark a gateway as disconnected or not. A gateway will become disconnected when the inactivity time becomes greater than (1/disconnection_sensitivity) times it usual period between up packages"}}','This was determined by not receiving packets from a gateway for a longer period of time than usual.','Check why the gateway has stopped sending packets.',0)
,('LAF-007','Possible duplicated sessions','Received smaller counter than expected for DevAddr {dev_addr} with DevEUI {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}). Application: {join_eui} {app_name}. Previous counter was {counter} and current {new_counter}. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','MEDIUM','Since it was received a message with a lower counter than expected, it may imply that an attacker has generated valid session keys and is sending data messages with an arbitrary payload.','{}','If an attacker obtains a pair of session keys (for having stolen the AppKey in OTAA devices or the AppSKey/NwkSKey in ABP devices), he/she would be able to send fake data to the server. For the server to accept spoofed messages, it is required for the FCnt (Frame Counter) of the message to be higher than the FCnt of the last message sent. In an scenario where the original spoofed device keeps sending messages, the server would start to discard (valid) messages since they would have a smaller FCnt. Hence, when messages with a smaller FCnt value than expected by the lorawan server are being received, it is possible to infer that a parallel session was established.','If the device is over the air activated (OTAA), change its AppKey because it was probably compromised. If it is activated by personalization, change its AppSKey and NwkSKey. Moreover, make sure that the lorawan server is updated and it is not accepting duplicated messages.',1296000)
,('LAF-009','Easy to guess key','Key {app_key} found for device with DevEUI {dev_eui} and DevAddr {dev_addr} (device name: {dev_name}, device vendor: {dev_vendor}).  Application: {join_eui} {app_name}. Matched {packet_type_1} message {packet_id_1}. {packet_type_2} message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.','HIGH','The AppKey of the device was guessed.','{}','The AppKey of the device was found trying with a well-known or nonrandom string. It was decrypted using a pair of join messages (Request and Accept).','Use a random keys generator for the AppKey instead of using ones provided by vendors. Moreover, do not set the same AppKey to more than one device and do not generate AppKeys using a predictable logic (eg. incremental values, flip certain bytes, etc.)',0)
,('LAF-010','Gateway changed location','Gateway {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}) may have been moved. Previous latitude {old_latitude}, current latitute {new_latitude}. Previous longitude {old_longitude}, current longitude {new_longitude}. Current message {packet_id} received on {packet_date}.
Alert generated on {created_at}.','MEDIUM','Since the gateway is not supposed to change its location, it may have been stolen or moved.','{"location_accuracy": {"type": "Float", "default": 20, "maximum": 1000000, "minimum": 0, "description": "Missing description" }}','Other possible cause could be an attacker with a fake gateway trying to impersonate the legitimate Gateway.','Make sure the gateway was not tampered, both physically or logically.',0)
,('LAF-600','Issue solved','{alert_solved} {alert_description} {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor})
{date}','INFO','An issue has been solved','{}','The issue is considered solved since a considerable time has passed since the last alert was emitted. This could indicate that the problem was resolved or that the device stopped transmitting.','',0)
;

-- Policy --
INSERT INTO public.policy (name, organization_id, is_default) VALUES ('Default', NULL, true);

-- Policy Item --
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-001');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', false, 1, 'LAF-002');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-006');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-007');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-009');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{"location_accuracy":20}', true, 1, 'LAF-010');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-011');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-400');
INSERT INTO public.policy_item (parameters, enabled, policy_id, alert_type_code) VALUES ('{}', true, 1, 'LAF-401');

-- Data Collector
INSERT INTO public.data_collector(data_collector_type_id, name, description, created_at, ip, port, "user", password, ssl, organization_id, deleted_at, policy_id, status, gateway_id, verified)
VALUES(1, 'Chirpstack.io Test', 'Chirpstack.io Test Open Server', '2020-03-01 12:40:52.306', '182.48.244.13', '1883', NULL, NULL, false, 4, NULL, 1, 'CONNECTED', NULL, true);


--
-- TOC entry 3038 (class 0 OID 99715)
-- Dependencies: 200
-- Data for Name: app_key; Type: TABLE DATA; Schema: public; Owner: postgres
--

--
-- TOC entry 3058 (class 0 OID 99767)
-- Dependencies: 220
-- Data for Name: packet; Type: TABLE DATA; Schema: public; Owner: postgres
--


COPY public.device_vendor_prefix (id, prefix, vendor)
FROM '/data/device_vendor_prefix.csv'
DELIMITER ';'
CSV HEADER;


--
-- TOC entry 3060 (class 0 OID 99775)
-- Dependencies: 222
-- Data for Name: row_processed; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO public.row_processed (id, last_row, analyzer) VALUES (1, 0, 'bruteforcer');
INSERT INTO public.row_processed (id, last_row, analyzer) VALUES (3, 0, 'printer');
INSERT INTO public.row_processed (id, last_row, analyzer) VALUES (2, 0, 'packet_analyzer');


--
-- TOC entry 3067 (class 0 OID 0)
-- Dependencies: 197
-- Name: alert_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

-- SELECT pg_catalog.setval('public.alert_id_seq', 106, true);


-- --
-- -- TOC entry 3068 (class 0 OID 0)
-- -- Dependencies: 199
-- -- Name: alert_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.alert_type_id_seq', 32, true);


-- --
-- -- TOC entry 3069 (class 0 OID 0)
-- -- Dependencies: 201
-- -- Name: app_key_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.app_key_id_seq', 1, false);


-- --
-- -- TOC entry 3070 (class 0 OID 0)
-- -- Dependencies: 203
-- -- Name: data_collector_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.data_collector_id_seq', 1, true);


-- --
-- -- TOC entry 3071 (class 0 OID 0)
-- -- Dependencies: 207
-- -- Name: dev_nonce_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.dev_nonce_id_seq', 1733, true);


-- --
-- -- TOC entry 3072 (class 0 OID 0)
-- -- Dependencies: 210
-- -- Name: device_auth_data_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.device_auth_data_id_seq', 1, false);


-- --
-- -- TOC entry 3073 (class 0 OID 0)
-- -- Dependencies: 211
-- -- Name: device_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.device_id_seq', 23, true);


-- --
-- -- TOC entry 3074 (class 0 OID 0)
-- -- Dependencies: 213
-- -- Name: device_session_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.device_session_id_seq', 26, true);


-- --
-- -- TOC entry 3075 (class 0 OID 0)
-- -- Dependencies: 215
-- -- Name: gateway_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.gateway_id_seq', 1, false);


-- --
-- -- TOC entry 3076 (class 0 OID 0)
-- -- Dependencies: 219
-- -- Name: organization_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.organization_id_seq', 1, true);


-- --
-- -- TOC entry 3077 (class 0 OID 0)
-- -- Dependencies: 221
-- -- Name: packet_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.packet_id_seq', 12000, true);


-- --
-- -- TOC entry 3078 (class 0 OID 0)
-- -- Dependencies: 223
-- -- Name: row_processed_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
-- --

-- SELECT pg_catalog.setval('public.row_processed_id_seq', 3, true);


-- Completed on 2019-05-16 15:53:30 UTC


--
-- PostgreSQL database dump complete
--

-- Fix/missing notification preferences (V1.3)

INSERT INTO public.notification_preferences (user_id, sms, push, email) VALUES(2, false, true, false);
INSERT INTO public.notification_alert_settings (user_id, high, medium, low, info) VALUES(2, true, true, false, false);
INSERT INTO public.notification_data_collector_settings (enabled, user_id, data_collector_id) VALUES(true, 2, 1);


-- Feature/ filter notification by asset importance (v1.4)
INSERT INTO public.notification_asset_importance (user_id, high, medium, low) VALUES(2, true, true, false);


-- Feature/alert_trying_to_connect
INSERT INTO public.alert_type (code,name,message,risk,description,parameters,technical_description,recommended_action,quarantine_timeout) VALUES 
('LAF-404',
 'Device failed to join',
 'The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor})  {app_name} Message ID received {packet_id} on {packet_date} from gateway {gateway} (gateway name: {gw_name}, gw_vendor: {gw_vendor}. Alert generated on {created_at}.',
 'LOW',
 'Device is sending many join requests but it is not joining to the network.',
 '{"max_join_request_fails": {"type": "Float", "default": 10, "maximum": 1000000, "minimum": 2, "description": "Max number of join requests sent by a device without getting to connect to any network" }}',
 'A device has sent many join requests without being able to connect to any network.','Check if device belongs to your LoRaWAN network.',
 1209600)
;

-- Add automatic problem solved issue resolution reason
INSERT INTO public.quarantine_resolution_reason (id, "type","name",description) VALUES 
(1, 'MANUAL','Manual','Manually resolved quarantine'),
(2, 'AUTOMATIC','Timeout','Enough time has passed without alerts'),
(3, 'AUTOMATIC','Correct','Checks passed'),
(0, 'AUTOMATIC','Problem solved','The quarantine was removed since the vulnerability was solved.');

-- Feature/alert_laf_102
INSERT INTO public.alert_type (code,name,message,risk,description,parameters,technical_description,recommended_action,quarantine_timeout) VALUES 
('LAF-102',
'Device signal to noise ratio below threshold',
'The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) has joined the network. 
Application: {join_eui} There are {number_of_devices} devices connected in this data collector.
Message ID received {packet_id} on {packet_date} from gateway {gateway} (gateway name: {gw_name}, gw_vendor: {gw_vendor}. 
{rssi} Alert generated on {created_at}.',
'LOW',
'A packet from this device was received with a signal to noise ratio below the threshold set in the policy.',
'{
   "minimum_lsnr":{
      "type":"Float",
      "default": -15,
      "maximum": 10,
      "minimum": -20,
      "description":"Minimum LSNR accepted, if the signal to noise ratio is lower an alert is emitted."
   }
}',
'The signal to noise ratio of the device is too low, this can cause packet losing, duplicate packets and faster battery draining.',
'Try to get the device and the gateway closer. If this is not possible, consider adding another gateway to increase the coverage. You should
also consider removing any interferences between this two points',
3600);

-- Update existing alert_types to set the correspondig for_asset_type value to each of them
UPDATE public.alert_type
SET for_asset_type = 'DEVICE'
WHERE code in ('LAF-001', 'LAF-002', 'LAF-006', 'LAF-007', 'LAF-009', 'LAF-011',
                'LAF-100', 'LAF-101', 'LAF-102',
                'LAF-400', 'LAF-401', 'LAF-404',
                'LAF-500', 'LAF-501', 'LAF-503');

UPDATE public.alert_type
SET for_asset_type = 'GATEWAY'
WHERE code in ('LAF-010', 'LAF-402', 'LAF-403');

UPDATE public.alert_type
SET for_asset_type = 'LOOK_IN_ALERT_PARAMS'
WHERE code in ('LAF-600', 'LAF-601');

--  Update threshold for Gateway changed location, and add description for the parameter
update policy_item set parameters = '{"location_accuracy": 50}' where alert_type_code = 'LAF-010';
update alert_type set parameters = '{"location_accuracy": {"type": "Float", "default": 50, "maximum": 1000000, "minimum": 0, "description": "Meter-measured. Gateway''s movements that are greater than this value cause an alert to be raised." }}' where code = 'LAF-010';

-- Delete device_id and device_session_id for gateways' alerts/issues
UPDATE alert
SET    device_id = NULL,
       device_session_id = NULL
WHERE  type IN ( 'LAF-010', 'LAF-402', 'LAF-403' )
       AND ( device_id is NOT NULL
              OR device_session_id IS NOT NULL );
                                                                                     
UPDATE quarantine
SET    device_id = NULL,
       device_session_id = NULL
WHERE  quarantine.id IN (SELECT quarantine.id
                         FROM   quarantine
                                INNER JOIN alert
                                        ON quarantine.alert_id = alert.id
                         WHERE  alert."type" IN ( 'LAF-010', 'LAF-402',
                                                  'LAF-403' )
                                AND ( quarantine.device_id IS NOT NULL
                                       OR quarantine.device_session_id IS NOT NULL )
                                       order by quarantine.since desc
                        );

-- Add min_activity_period and deviation_tolerance parameters for connection lost alerts (gateway's and device's)
-- Device
update alert_type SET parameters = '{"disconnection_sensitivity": {"type":"Float","default":0.05,"maximum":1.0,"minimum":0.00001,"description":"Used when deciding whether to mark a device as disconnected or not. A device will become disconnected when the inactivity time becomes greater than (1/disconnection_sensitivity) times it usual period between up packages"},
"min_activity_period": {"type":"Float","default":1800,"maximum":7200,"description":"Used as disconnection threshold when (1/disconnection_sensitivity) times the estimated frequency is lower than this value"},
"deviation_tolerance": {"type":"Float","default":0.20,"maximum":1.00,"minimum":0.00,"description":"Used to decide whether to raise an alert or not when a device is marked as disconnected. The status (connected/disconnected) of a device depends on its mean period between messages and its inactivity time, therefore this alert may not be useful for irregular devices. Then, an alert will only be raised for devices that sends messages with a coefficient of deviation (standard_deviation/mean) not higher than the value of this parameter"}}' 
where code = 'LAF-401';
-- Gateway
update alert_type set parameters = '{"disconnection_sensitivity": {"type":"Float","default":0.05,"maximum":1.0,"minimum":0.00001,"description":"Used when deciding whether to mark a gateway as disconnected or not. A gateway will become disconnected when the inactivity time becomes greater than (1/disconnection_sensitivity) times it usual period between up packages"},
"min_activity_period": {"type":"Float","default":1800,"maximum":7200,"description":"Used as disconnection threshold when (1/disconnection_sensitivity) times the estimated frequency is lower than this value"}}'
where code = 'LAF-403';

-- Delete LAF-500 from system
DELETE FROM policy_item
WHERE  alert_type_code = 'LAF-500';

DELETE FROM quarantine
WHERE  quarantine.id IN (SELECT quarantine.id
                         FROM   quarantine
                                INNER JOIN alert
                                        ON quarantine.alert_id = alert.id
                         WHERE  alert."type" = 'LAF-500');

DELETE FROM notification
WHERE  notification.id IN (SELECT notification.id
                           FROM   notification
                                  INNER JOIN alert
                                          ON notification.alert_id = alert.id
                           WHERE  alert."type" = 'LAF-500');

DELETE FROM alert
WHERE  "type" = 'LAF-500';

DELETE FROM alert_type
WHERE  code = 'LAF-500'; 

-- Alert types changes 
UPDATE alert_type
SET    risk = 'MEDIUM'
WHERE  code = 'LAF-001';

UPDATE alert_type
SET    "name" = 'Device AppKey found'
WHERE  code = 'LAF-009';

UPDATE alert_type
SET    "name" = 'Device losing many messages',
       description =
'The device is losing more messages than the threshold set in the policy.',
technical_description =
'There is a problem in the link, many messages of this device are being lost.'
WHERE  code = 'LAF-101';

UPDATE alert_type
SET    "name" = 'New gateway'
WHERE  code = 'LAF-402';

UPDATE alert_type
SET    risk = 'MEDIUM',
       message = 'The gateway {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}) has not send messages for a long period of time.
Alert generated on {created_at}.',
       description =
'A gateway has not send messages for a long period of time. It might be disconnected.'
       ,
technical_description =
'This was determined by not receiving messages from a gateway for a longer period of time than usual.'
       ,
recommended_action =
'Check why the gateway has stopped sending messages.'
WHERE  code = 'LAF-403';

UPDATE alert_type
SET    message = 'The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) has not send messages for a long period of time.  Application: {join_eui} {app_name}. There are {number_of_devices} devices connected in this data collector.
Alert generated on {created_at}.',
       description =
'A device has not send messages for a long period of time. It might be disconnected.'
       ,
recommended_action =
'Check why the device has stopped sending messages.'
WHERE  code = 'LAF-401';

UPDATE alert_type
SET    description =
'A message from this device was received with an signal strength below the threshold set in the policy.'
       ,
technical_description =
'The signal strength of the device is too low, this can cause message losing, duplicate messages and faster battery draining.'
WHERE  code = 'LAF-100';

UPDATE alert_type
SET    description =
       'One variable of a received message presents an abnormal value.',
       technical_description =
'The value of one of the analyzed variables is abnormal. This behaviour could be generated by several reasons, and is not enought to conclude that the message was generated by an attacker. If more abnormal values are detected, a LAF-503 is emited.'
WHERE  code = 'LAF-500';

UPDATE alert_type
SET    description =
       'Some variables of a received message present abnormal values.',
       technical_description =
'The signal power, size of data, time between messages and counter behaviour are abnormal. This could indicate that the message was generated by an attacker.'
       ,
recommended_action =
'Keep track of the messages sent by this device and check whether the traffic and its data is normal.'
WHERE  code = 'LAF-503';

UPDATE alert_type
SET    description =
'A message from this device was received with a signal to noise ratio below the threshold set in the policy.'
       ,
technical_description =
'The signal to noise ratio of the device is too low, this can cause message losing, duplicate messages and faster battery draining.'
WHERE  code = 'LAF-102';


-- Updated alerts LAF-007, LAF-011 and LAF-006

UPDATE public.alert_type
SET code='LAF-006', "name"='Possible ABP device', message='DevAddr {dev_addr} with DevEUI {dev_eui} counter was reset (device name: {dev_name}, device vendor: {dev_vendor}). Previous counter was {counter} and received {new_counter}. Application: {join_eui} {app_name}. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway}, gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.', risk='HIGH', description='If the counter was reset (came back to 0), the DevAddr is kept the same, and no previous Join process was detected, may imply that the device is Activated By Personalization (ABP), which is discouraged for security reasons.

Another posibility is that the device have reseted the counter intentionally or be malfunctioning.

LoRaWAN network servers usually reject messages with lower counters but this validation can  be disabled at the network server.
', parameters='{}', technical_description='ABP devices implies that session keys are never changed in the whole lifecycle of the device. A device that does not change its session keys is prone to different attacks such as eaveasdrop or replay.', recommended_action='All activated by personalization (ABP) devices should be replaced for over the air activated (OTAA) devices if possible.', quarantine_timeout=604800, for_asset_type='DEVICE'
where code = 'LAF-006';

UPDATE public.alert_type
SET code='LAF-011', "name"='Device not re-generating session keys', message='DevAddr {dev_addr} with DevEUI {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) counter was reset. Previous counter was {counter} and received {new_counter}. This device is not rejoining after counter overflow. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.', risk='HIGH', description='If the device was identified as OTAA, the counter was reset (came back to 0), the DevAddr is kept the same, and no previous Join was detected, it may imply that the device is not going through a re-join process when its counter is overflowed (from 65535 to 0).

Another posibility is that the device have reseted the counter intentionally or be malfunctioning.

LoRaWAN network servers usually reject messages with lower counters but this validation can  be disabled at the network server. ', parameters='{}', technical_description='If sessions keys are not renewed, the device is exposed to eavesdropping attacks.', recommended_action='Force the device to start a Join process when its counter is overflowed.', quarantine_timeout=604800, for_asset_type='DEVICE'
where code = 'LAF-011';

UPDATE public.alert_type
SET code='LAF-007', "name"='Possible duplicated sessions', message='Received smaller counter than expected for DevAddr {dev_addr} with DevEUI {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}). Application: {join_eui} {app_name}. Previous counter was {counter} and current {new_counter}. Previous message {prev_packet_id}, current message {packet_id} received on {packet_date} from gateway ID {gateway} (gateway name: {gw_name}, gateway vendor: {gw_vendor}).
Alert generated on {created_at}.', risk='MEDIUM', description='Was received a message with a lower counter than expected. It may imply that the device is malfunctioning, or that an attacker has generated valid session keys and is sending data messages with an arbitrary payload.

LoRaWAN network servers usually reject messages with lower counters but this validation could be disabled at the network server.
', parameters='{}', technical_description='If an attacker obtains a pair of session keys (for having stolen the AppKey in OTAA devices or the AppSKey/NwkSKey in ABP devices), he/she would be able to send fake data to the server. For the server to accept spoofed messages, it is required for the FCnt (Frame Counter) of the message to be higher than the FCnt of the last message sent. In an scenario where the original spoofed device keeps sending messages, the server would start to discard (valid) messages since they would have a smaller FCnt. Hence, when messages with a smaller FCnt value than expected by the lorawan server are being received, it is possible to infer that a parallel session was established.', recommended_action='If the device is over the air activated (OTAA), change its AppKey because it was probably compromised. If it is activated by personalization, change its AppSKey and NwkSKey. Moreover, make sure that the lorawan server is updated and it is not accepting duplicated messages.', quarantine_timeout=86400, for_asset_type='DEVICE'
where code = 'LAF-007';

-- Feature/LAF-103
INSERT INTO alert_type
            (code,
             "name",
             message,
             risk,
             description,
             parameters,
             technical_description,
             recommended_action,
             quarantine_timeout,
             for_asset_type)
VALUES      ('LAF-103',
             'Too many retransmissions by device',
             'The device {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) is sending the same message too many times.  Application: {join_eui} {app_name}. Alert generated on {created_at}.',
             'MEDIUM',
'The device is retransmitting too many messages, according to threshold set in policy'
             ,
'{"max_retransmissions":  {"type":"Integer","default":10,"maximum":1000000,"minimum":0,"description":"Represents a threshold of allowed retransmissions in a certain period of time. If a number or retransmissions that is higher than this value was detected in the last (time_window) hours, an alert will be raised"}, "time_window": {"type":"Integer","default":24,"maximum":24,"minimum":1, "description":"Represents the amount of time that is taken into account when deciding if the number of retransmissions by device should raise an alert. Measured in hours, can take a maximum value of 24, representing a time window of a day"}}'
             ,
'The device is retransmitting the same message too many times because it doesn''t receive the confirmations from LoRaWAN Network Server. This can lead to increased device''s battery consumption and data not being received by the application.'
             ,
'Check that the acknowledgment message from LoRaWAN Network Server is being received, and that the device is not malfunctioning.',
86400,
'DEVICE');

-- Feature/LAF-101
UPDATE alert_type
SET    "name" = 'Many messages from device are being lost',
       parameters =
'{"max_lost_packets": {"type": "Integer", "default": 360, "maximum": 10000000, "minimum": 0, "description": "Represents a threshold of allowed lost packets in a certain period of time. If a number or lost packets that is higher than this value was detected in the last (time_window) hours, an alert will be raised"}, "time_window": {"type":"Integer","default":24,"maximum":24,"minimum":1, "description":"Represents the amount of time that is taken into account when deciding if the number of lost packets by device should raise an alert. Measured in hours, can take a maximum value of 24, representing a time window of a day"}}'
WHERE  code = 'LAF-101';

-- Feature/LAF-600 - Add resolution_reason to message and delete second sentence on technical description
UPDATE public.alert_type
SET technical_description = 'The problem is considered resolved, see the Resolution reason for more details.',
    message = '{alert_solved} {alert_description} {dev_eui} (device name: {dev_name}, device vendor: {dev_vendor}) {date} {resolution_reason}'
WHERE code = 'LAF-600';



-- Added moving average weight to policies

UPDATE public.alert_type
	SET parameters='{
	"minimum_rssi": {
		"type": "Float",
		"default": -125,
		"maximum": 0,
		"minimum": -132,
		"description": "Minimum RSSI accepted, if the signal strength is lower an alert is emitted."
		},
	"moving_average_weight": {
	"type": "Float",
	"default": 0.9,
	"maximum": 0.99,
	"minimum": 0.0,
	"description" : "This value is related to how many packets are averaged to calculate the mean signal intensity. The higher the value, the greater the number of packets considered in the average."
	}
}'
	WHERE code='LAF-100';
UPDATE public.alert_type
	SET parameters='{
   "minimum_lsnr":{
      "type":"Float",
      "default": -15,
      "maximum": 10,
      "minimum": -20,
      "description":"Minimum LSNR accepted, if the signal to noise ratio is lower an alert is emitted."
   }, 
   "moving_average_weight": {
   "type": "Float",
   "default": 0.9,
   "maximum": 0.99,
   "minimum": 0.0,
   "description" : "This value is related to how many packets are averaged to calculate the mean SNR. The higher the value, the greater the number of packets considered in the average."
   }
}'
	WHERE code='LAF-102';
UPDATE public.alert_type
	SET parameters='{"disconnection_sensitivity": {"type":"Float","default":0.05,"maximum":1.0,"minimum":0.00001,"description":"Used when deciding whether to mark a device as disconnected or not. A device will become disconnected when the inactivity time becomes greater than (1/disconnection_sensitivity) times it usual period between up packages"},
"min_activity_period": {"type":"Float","default":1800,"maximum":7200,"description":"Used as disconnection threshold when (1/disconnection_sensitivity) times the estimated frequency is lower than this value"},
"deviation_tolerance": {"type":"Float","default":0.20,"maximum":1.00,"minimum":0.00,"description":"Used to decide whether to raise an alert or not when a device is marked as disconnected. The status (connected/disconnected) of a device depends on its mean period between messages and its inactivity time, therefore this alert may not be useful for irregular devices. Then, an alert will only be raised for devices that sends messages with a coefficient of deviation (standard_deviation/mean) not higher than the value of this parameter"},
"moving_average_weight":
{
	"type": "Float",
	"default": 0.9,
	"maximum": 0.99,
	"minimum": 0.0,
	"description" : "This value is related to how many packets are used to estimate the frequency of transmission. The higher the value, the greater the number of packets considered in the average."
   }
}'
	WHERE code='LAF-401';
UPDATE public.alert_type
	SET parameters='{"disconnection_sensitivity": {"type":"Float","default":0.05,"maximum":1.0,"minimum":0.00001,"description":"Used when deciding whether to mark a gateway as disconnected or not. A gateway will become disconnected when the inactivity time becomes greater than (1/disconnection_sensitivity) times it usual period between up packages"},
"min_activity_period": {"type":"Float","default":1800,"maximum":7200,"description":"Used as disconnection threshold when (1/disconnection_sensitivity) times the estimated frequency is lower than this value"},
"moving_average_weight":
{
	"type": "Float",
	"default": 0.9,
	"maximum": 0.99,
	"minimum": 0.0,
	"description" : "This value is related to how many packets are used to estimate the frequency of transmission. The higher the value, the greater the number of packets considered in the average."
   }
}'
	WHERE code='LAF-403';

-- Corrected LAF-401 description
UPDATE public.alert_type
	SET technical_description='This was determined by not receiving messages from a gateway for a longer period of time than usual.'
	WHERE code='LAF-401';

-- Update timeouts and number of packets to remove issues
UPDATE public.alert_type
	SET quarantine_timeout=86400,quarantine_npackets_timeout=8
	WHERE id=38;
UPDATE public.alert_type
	SET quarantine_timeout=86400,quarantine_npackets_timeout=8
	WHERE id=18;
UPDATE public.alert_type
	SET quarantine_timeout=86400,quarantine_npackets_timeout=8
	WHERE id=19;
UPDATE public.alert_type
	SET quarantine_timeout=604800
	WHERE id=40;
UPDATE public.alert_type
	SET quarantine_timeout=604800
	WHERE id=23;
UPDATE public.alert_type
	SET quarantine_timeout=86400,quarantine_npackets_timeout=8
	WHERE id=39;
UPDATE public.alert_type
	SET quarantine_timeout=86400,quarantine_npackets_timeout=8
	WHERE id=41;
UPDATE public.alert_type
	SET quarantine_timeout=604800
	WHERE id=24;
UPDATE public.alert_type
	SET quarantine_timeout=86400,quarantine_npackets_timeout=8
	WHERE id=42;

INSERT INTO public.notification_type(code) VALUES ('NEW_ALERT');

DELETE FROM public.data_collector_type WHERE id=2;