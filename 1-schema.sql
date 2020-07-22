--
-- PostgreSQL database dump
--

-- Dumped from database version 10.6
-- Dumped by pg_dump version 11.2

-- Started on 2020-02-13 12:43:56 -03

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 4482 (class 0 OID 0)
-- Dependencies: 8
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- TOC entry 930 (class 1247 OID 21629)
-- Name: datacollectorlogeventtype; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.datacollectorlogeventtype AS ENUM (
    'CONNECTED',
    'DISCONNECTED',
    'DISABLED',
    'CREATED',
    'UPDATED',
    'ENABLED',
    'RESTARTED',
    'FAILED_PARSING',
    'DELETED',
    'FAILED_LOGIN'
);


ALTER TYPE public.datacollectorlogeventtype OWNER TO postgres;

--
-- TOC entry 927 (class 1247 OID 21332)
-- Name: datacollectorstatus; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.datacollectorstatus AS ENUM (
    'CONNECTED',
    'DISCONNECTED',
    'DISABLED'
);


ALTER TYPE public.datacollectorstatus OWNER TO postgres;

--
-- TOC entry 972 (class 1247 OID 31589)
-- Name: quarantine_risk; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.quarantine_risk AS ENUM (
    'LOW',
    'MEDIUM',
    'HIGH'
);


ALTER TYPE public.quarantine_risk OWNER TO postgres;

--
-- TOC entry 1008 (class 1247 OID 50850)
-- Name: quarantineresolutionreasontype; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.quarantineresolutionreasontype AS ENUM (
    'MANUAL',
    'AUTOMATIC'
);


ALTER TYPE public.quarantineresolutionreasontype OWNER TO postgres;

--
-- TOC entry 1015 (class 1247 OID 32672)
-- Name: quarantinerisk; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.quarantinerisk AS ENUM (
    'LOW',
    'MEDIUM',
    'HIGH'
);


ALTER TYPE public.quarantinerisk OWNER TO postgres;


--
-- TOC entry 419 (class 1255 OID 94685)
-- Name: populate_stats_counters_v5(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.populate_stats_counters_v5() RETURNS boolean
    LANGUAGE plpgsql
    AS $$

DECLARE
	_from timestamp;
	_to timestamp;

	last_existing_record timestamp;                 -- last existing record in stats counters.

	-- This procedure loops over different hours...
	first_timestamp_to_process timestamp;           -- the first hour to process.
	last_timestamp_to_process timestamp;            -- the last hour to process.
	timestamp_being_processed timestamp;            -- the hour being processed.

	exist_row timestamp;                            -- not null if the date to be filled is already in stats counters (in this case, we have to update rows, not insert), else null.

	-- For counting devices we look at the sessions that were active concurrently within each 1-hour window.
	-- To do this we fetch the min and max timestamps from each session and then we sample every minute within the hour and check how many sessions were active at that minute.
	device_count_loop_org_collector_pair record;    -- a row containing org id + collector id, used to loop over all the existing combinations.
	device_count_loop_organization_id int;          -- the org id being processed at a loop pass.
	device_count_loop_collector_id int;             -- the collector being processed at a loop pass.
	minute_loop_timestamp timestamp;                -- the minute being analyzed.
	minute_loop_sessions int;                       -- the number of sessions found in the minute being analyzed.
	minute_loop_max_sessions int;                   -- the max number of sessions found within the hour.

	-- For counting devices, there is also a combination of problems require some additional logic here:
	--   1- The insertion of packets into the packet table may be delayed, possibly more than 30 mins.
	--      To address this we need to keep re-processing the last past hour so packets that arrived in the current hour with a timestamp from the last hour are included in the sessions counting.
	--   2- Some crazy sessions span across several hours and they send packets very infrequently - we've observed up to 4 hours of difference between consecutive packets.
	--      To address this we need to "look back" into a few past hours to correlate packets in the hour being processed with their predecessor in the session.
	--      Also since we are re-processing the last hour we can take advantage and "look forward" into the the current hour to find correlated packets.
	device_session_lookup_start timestamp;
	device_session_lookup_end timestamp;

	-- For hours without packets we create a dummy record with random organization and collector to mark that we've already processed that hour.
	random_organization_id int;
	random_data_collector_id int;

BEGIN

	SELECT dc.organization_id, dc.id INTO random_organization_id, random_data_collector_id FROM data_collector dc LIMIT 1;

	SELECT max(stats_counters.hour) INTO last_existing_record FROM stats_counters;

	-- Populate up to the current hour.
	last_timestamp_to_process := date_trunc('hour', now()::timestamp);

	-- Figure out how far in the past we need to go to backfill missing data.
	IF last_existing_record is null THEN
		-- If there is no data at all in the table let's not go crazy, populate only the current hour.
		first_timestamp_to_process := last_timestamp_to_process;
	ELSE
		-- If there are records for the current hour already (last_existing_record = last_timestamp_to_process), only update those counters.
		-- If there are no records for the current hour (last_existing_record <> last_timestamp_to_process) it means that at least one hour has been wrapped since the last call to this procedure so we need to re-process the last processed hour one more time to include the last packets.
		-- In both cases we just need to start processing the last existing record :)
		first_timestamp_to_process := last_existing_record;
	END IF;

	-- Ensure to reprocess hours when needed.
	IF first_timestamp_to_process = last_timestamp_to_process THEN
		first_timestamp_to_process := first_timestamp_to_process - interval '1 hours';
	END IF;

	timestamp_being_processed := first_timestamp_to_process;

	WHILE timestamp_being_processed <= last_timestamp_to_process LOOP
		_from := timestamp_being_processed;
		_to := timestamp_being_processed + interval '1 hours';
		timestamp_being_processed := _to;
		RAISE NOTICE 'Processing from % to %.', _from, _to;

		SELECT sc.hour INTO exist_row FROM stats_counters sc WHERE sc.hour = _from;

		-- If there are no stats_counters records for the hour, and there are no packets for that hour, and the hour is in the past we create a dummy record with random organization and collector to mark that we've already processed that hour.
		IF (exist_row IS NULL) AND (NOT EXISTS (SELECT 1 FROM packet WHERE date >= _from AND date < _to)) AND (_from <> last_timestamp_to_process) THEN
			RAISE NOTICE 'No packets found, creating a dummy record with organization_id = %, data_collector_id = %...', random_organization_id, random_data_collector_id;
			INSERT INTO stats_counters(hour, packets_count, joins_count, alerts_count, organization_id, devices_count, data_collector_id)
				VALUES (_from, 0, 0, 0, random_organization_id, 0, random_data_collector_id);
			CONTINUE;
		END IF;

		-- Create new rows for any combination of [organization, collector] that is untracked for this hour, update the rows for the rest.
		RAISE NOTICE 'Inserting stats_counters records for each new [organization, collector] pair found in [%, %]...', _from, _to;
		INSERT INTO stats_counters(hour, packets_count, joins_count, alerts_count, organization_id, devices_count, data_collector_id)
			SELECT _from AS hour, 0, 0, 0, organization_id, 0, data_collector_id
			FROM packet p
			WHERE (p.date >= _from)
			AND (p.date < _to)
			AND NOT EXISTS (
				SELECT 1 FROM stats_counters sc2
				WHERE sc2.organization_id = p.organization_id
				AND sc2.data_collector_id = p.data_collector_id
				AND sc2.hour = _from)
			GROUP BY organization_id, data_collector_id;

		RAISE NOTICE 'Updating packet counts...';
		UPDATE stats_counters
		SET packets_count=packets_subquery.count
		FROM(SELECT _from AS hour, count(1) AS count, organization_id, data_collector_id
			FROM packet
			WHERE date >= _from AND date < _to
			GROUP BY data_collector_id, organization_id) AS packets_subquery
		WHERE stats_counters.hour = packets_subquery.hour
		AND stats_counters.organization_id = packets_subquery.organization_id
		AND stats_counters.data_collector_id = packets_subquery.data_collector_id;

		RAISE NOTICE 'Updating join counts...';
		UPDATE stats_counters
		SET joins_count=subquery.count
		FROM (SELECT _from AS hour, count(1) AS count, organization_id, data_collector_id
			FROM packet
			WHERE date >= _from AND date < _to AND m_type='JoinRequest'
			GROUP BY data_collector_id,organization_id) AS subquery
		WHERE stats_counters.hour = subquery.hour
		AND stats_counters.organization_id = subquery.organization_id
		AND stats_counters.data_collector_id = subquery.data_collector_id;

		RAISE NOTICE 'Updating alert counts...';
		UPDATE stats_counters
		SET alerts_count=alerts_subquery.count
		FROM (SELECT _from AS hour, count(1) AS count, organization_id, data_collector_id
			FROM alert a
			JOIN data_collector dc
			ON a.data_collector_id=dc.id
			WHERE a.created_at >= _from AND a.created_at < _to
			GROUP BY data_collector_id,organization_id) AS alerts_subquery
		WHERE stats_counters.hour=alerts_subquery.hour
		AND stats_counters.organization_id=alerts_subquery.organization_id
		AND stats_counters.data_collector_id=alerts_subquery.data_collector_id;

		-- START: device counts.

		-- Use a temp table to hold the sessions by organization by collector, within the hour being processed.
		CREATE TEMP TABLE device_sessions_temp(
			organization_id bigint,
			data_collector_id bigint,
			dev_addr varchar(8),
			min_date timestamptz,
			max_date timestamptz
		);

		-- Use "look back" and "look forward" time to augment the window we use to find active sessions.
		-- See comment in the declaration of these variables explaining why we need this.
		device_session_lookup_start := _from - interval '4 hours';
		device_session_lookup_end := _to + interval '1 hours';

		INSERT INTO device_sessions_temp(organization_id, data_collector_id, dev_addr, min_date, max_date)
			SELECT p.organization_id, p.data_collector_id, p.dev_addr, min(p."date") AS min_date, max(p."date") AS max_date
			FROM packet p
			WHERE p.dev_addr IS NOT NULL
			AND p."date" BETWEEN device_session_lookup_start AND device_session_lookup_end
			GROUP BY 1, 2, 3
			HAVING count(*) > 1;

		-- Loop over all the [organization, collector] combinations and update the device counts.
		FOR device_count_loop_org_collector_pair IN
			SELECT DISTINCT organization_id, data_collector_id
			FROM device_sessions_temp
			ORDER BY 1 ASC, 2 ASC
		LOOP
			device_count_loop_organization_id := device_count_loop_org_collector_pair.organization_id;
			device_count_loop_collector_id := device_count_loop_org_collector_pair.data_collector_id;

			-- Go over every minute in the hour and find the maximum number of concurrent sessions.
			minute_loop_timestamp := _from  + interval '1 minutes';
			minute_loop_max_sessions := 0;
			RAISE NOTICE 'Analyzing device sessions for organization %, collector %.', device_count_loop_organization_id, device_count_loop_collector_id;
			WHILE minute_loop_timestamp < _to LOOP
				RAISE NOTICE 'Analyzing device sessions at minute %.', minute_loop_timestamp;
				SELECT count(*)
					INTO minute_loop_sessions
					FROM device_sessions_temp ds
					WHERE minute_loop_timestamp BETWEEN ds.min_date AND ds.max_date
					AND ds.organization_id = device_count_loop_organization_id
					AND ds.data_collector_id = device_count_loop_collector_id;
				IF minute_loop_sessions IS NOT NULL THEN
					IF minute_loop_sessions > minute_loop_max_sessions THEN
						minute_loop_max_sessions := minute_loop_sessions;
					END IF;
				END IF;
				RAISE NOTICE 'Sessions: %.', minute_loop_max_sessions;
				minute_loop_timestamp := minute_loop_timestamp + interval '1 minutes';
			END LOOP;

			RAISE NOTICE 'Updating device counts for organization %, collector %.', device_count_loop_organization_id, device_count_loop_collector_id;
			UPDATE stats_counters
			SET devices_count = minute_loop_max_sessions
			WHERE hour = _from
			AND organization_id = device_count_loop_organization_id
			AND data_collector_id = device_count_loop_collector_id;

		END LOOP;

		DROP TABLE device_sessions_temp;

		-- END: device counts.

	END LOOP;

	RAISE NOTICE 'Done!';
	RETURN TRUE;

END;
$$;


ALTER FUNCTION public.populate_stats_counters_v5() OWNER TO postgres;


--
-- TOC entry 312 (class 1259 OID 19480)
-- Name: account_activation; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.account_activation (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying(500) NOT NULL,
    creation_date timestamp with time zone NOT NULL,
    active boolean NOT NULL,
    user_roles_id character varying(40)
);


ALTER TABLE public.account_activation OWNER TO postgres;

--
-- TOC entry 313 (class 1259 OID 19486)
-- Name: account_activation_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.account_activation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.account_activation_id_seq OWNER TO postgres;

--
-- TOC entry 4484 (class 0 OID 0)
-- Dependencies: 313
-- Name: account_activation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.account_activation_id_seq OWNED BY public.account_activation.id;


--
-- TOC entry 314 (class 1259 OID 19488)
-- Name: alert; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.alert (
    id bigint NOT NULL,
    type character varying(20) NOT NULL,
    created_at timestamp with time zone NOT NULL,
    packet_id bigint NOT NULL,
    device_id bigint,
    device_session_id bigint,
    gateway_id bigint,
    device_auth_id bigint,
    data_collector_id bigint NOT NULL,
    parameters character varying(4096) NOT NULL,
    resolved_at timestamp with time zone,
    resolved_by_id bigint,
    resolution_comment character varying(1024),
    show boolean DEFAULT true NOT NULL
);


ALTER TABLE public.alert OWNER TO postgres;

--
-- TOC entry 315 (class 1259 OID 19494)
-- Name: alert_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.alert_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.alert_id_seq OWNER TO postgres;

--
-- TOC entry 4485 (class 0 OID 0)
-- Dependencies: 315
-- Name: alert_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.alert_id_seq OWNED BY public.alert.id;


--
-- TOC entry 316 (class 1259 OID 19496)
-- Name: alert_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.alert_type (
    id bigint NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(120) NOT NULL,
    message character varying(4096),
    risk character varying(20) NOT NULL,
    description character varying(3000) NOT NULL,
    parameters character varying(4096) DEFAULT '{}'::character varying NOT NULL,
    technical_description character varying(3000),
    recommended_action character varying(3000),
    quarantine_timeout integer DEFAULT 0
);


ALTER TABLE public.alert_type OWNER TO postgres;

--
-- TOC entry 317 (class 1259 OID 19502)
-- Name: alert_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.alert_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.alert_type_id_seq OWNER TO postgres;

--
-- TOC entry 4486 (class 0 OID 0)
-- Dependencies: 317
-- Name: alert_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.alert_type_id_seq OWNED BY public.alert_type.id;


--
-- TOC entry 318 (class 1259 OID 19504)
-- Name: app_key; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.app_key (
    id bigint NOT NULL,
    key character varying(32) NOT NULL,
    organization_id bigint
);


ALTER TABLE public.app_key OWNER TO postgres;

--
-- TOC entry 319 (class 1259 OID 19507)
-- Name: app_key_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.app_key_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.app_key_id_seq OWNER TO postgres;

--
-- TOC entry 4487 (class 0 OID 0)
-- Dependencies: 319
-- Name: app_key_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.app_key_id_seq OWNED BY public.app_key.id;


--
-- TOC entry 320 (class 1259 OID 19509)
-- Name: change_email_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.change_email_requests (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    new_email character varying(120) NOT NULL,
    old_email character varying(120) NOT NULL,
    token character varying(500) NOT NULL,
    creation_date timestamp with time zone NOT NULL,
    active boolean NOT NULL
);


ALTER TABLE public.change_email_requests OWNER TO postgres;

--
-- TOC entry 321 (class 1259 OID 19515)
-- Name: change_email_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.change_email_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.change_email_requests_id_seq OWNER TO postgres;

--
-- TOC entry 4488 (class 0 OID 0)
-- Dependencies: 321
-- Name: change_email_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.change_email_requests_id_seq OWNED BY public.change_email_requests.id;


--
-- TOC entry 390 (class 1259 OID 34037)
-- Name: collector_message; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.collector_message (
    id bigint NOT NULL,
    data_collector_id bigint NOT NULL,
    packet_id bigint,
    message character varying(4096),
    topic character varying(512)
);


ALTER TABLE public.collector_message OWNER TO postgres;

--
-- TOC entry 389 (class 1259 OID 34035)
-- Name: collector_message_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.collector_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.collector_message_id_seq OWNER TO postgres;

--
-- TOC entry 4490 (class 0 OID 0)
-- Dependencies: 389
-- Name: collector_message_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.collector_message_id_seq OWNED BY public.collector_message.id;


--
-- TOC entry 322 (class 1259 OID 19517)
-- Name: data_collector; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.data_collector (
    id bigint NOT NULL,
    data_collector_type_id bigint NOT NULL,
    name character varying(120) NOT NULL,
    description character varying(1000),
    created_at timestamp with time zone NOT NULL,
    ip character varying(120),
    port character varying(120),
    "user" character varying(120),
    password character varying(120),
    ssl boolean,
    organization_id bigint NOT NULL,
    deleted_at timestamp with time zone,
    policy_id bigint,
    status public.datacollectorstatus,
    gateway_id character varying(120),
    verified boolean DEFAULT false
);


ALTER TABLE public.data_collector OWNER TO postgres;

--
-- TOC entry 323 (class 1259 OID 19523)
-- Name: data_collector_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.data_collector_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.data_collector_id_seq OWNER TO postgres;

--
-- TOC entry 4491 (class 0 OID 0)
-- Dependencies: 323
-- Name: data_collector_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.data_collector_id_seq OWNED BY public.data_collector.id;


--
-- TOC entry 367 (class 1259 OID 21649)
-- Name: data_collector_log_event; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.data_collector_log_event (
    id bigint NOT NULL,
    data_collector_id bigint NOT NULL,
    type public.datacollectorlogeventtype,
    created_at timestamp with time zone NOT NULL,
    parameters character varying(4096) NOT NULL,
    user_id bigint
);


ALTER TABLE public.data_collector_log_event OWNER TO postgres;

--
-- TOC entry 366 (class 1259 OID 21647)
-- Name: data_collector_log_event_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.data_collector_log_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.data_collector_log_event_id_seq OWNER TO postgres;

--
-- TOC entry 4492 (class 0 OID 0)
-- Dependencies: 366
-- Name: data_collector_log_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.data_collector_log_event_id_seq OWNED BY public.data_collector_log_event.id;


--
-- TOC entry 324 (class 1259 OID 19525)
-- Name: data_collector_to_device; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.data_collector_to_device (
    data_collector_id bigint NOT NULL,
    device_id bigint NOT NULL
);


ALTER TABLE public.data_collector_to_device OWNER TO postgres;

--
-- TOC entry 325 (class 1259 OID 19528)
-- Name: data_collector_to_device_session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.data_collector_to_device_session (
    data_collector_id bigint NOT NULL,
    device_session_id bigint NOT NULL
);


ALTER TABLE public.data_collector_to_device_session OWNER TO postgres;

--
-- TOC entry 402 (class 1259 OID 140812)
-- Name: data_collector_to_gateway; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.data_collector_to_gateway (
    data_collector_id bigint NOT NULL,
    gateway_id bigint NOT NULL
);


ALTER TABLE public.data_collector_to_gateway OWNER TO postgres;

--
-- TOC entry 326 (class 1259 OID 19531)
-- Name: data_collector_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.data_collector_type (
    id bigint NOT NULL,
    type character varying(30) NOT NULL,
    name character varying(50)
);


ALTER TABLE public.data_collector_type OWNER TO postgres;

--
-- TOC entry 327 (class 1259 OID 19534)
-- Name: data_collector_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.data_collector_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.data_collector_type_id_seq OWNER TO postgres;

--
-- TOC entry 4494 (class 0 OID 0)
-- Dependencies: 327
-- Name: data_collector_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.data_collector_type_id_seq OWNED BY public.data_collector_type.id;


--
-- TOC entry 328 (class 1259 OID 19541)
-- Name: dev_nonce; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dev_nonce (
    id bigint NOT NULL,
    dev_nonce integer,
    device_id bigint NOT NULL,
    packet_id bigint NOT NULL
);


ALTER TABLE public.dev_nonce OWNER TO postgres;

--
-- TOC entry 329 (class 1259 OID 19544)
-- Name: dev_nonce_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.dev_nonce_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dev_nonce_id_seq OWNER TO postgres;

--
-- TOC entry 4495 (class 0 OID 0)
-- Dependencies: 329
-- Name: dev_nonce_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.dev_nonce_id_seq OWNED BY public.dev_nonce.id;


--
-- TOC entry 330 (class 1259 OID 19546)
-- Name: device; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.device (
    id bigint NOT NULL,
    dev_eui character varying(16) NOT NULL,
	"name" varchar NULL,
	vendor varchar NULL,
    app_name varchar NULL,
    join_eui character varying(16),
    organization_id bigint NOT NULL,
    first_up_timestamp timestamp with time zone,
    last_up_timestamp timestamp with time zone,
    repeated_dev_nonce boolean,
    join_request_counter integer NOT NULL,
    join_accept_counter integer NOT NULL,
    has_joined boolean,
    join_inferred boolean,
    is_otaa boolean,
    last_packet_id bigint,
    connected boolean DEFAULT true NOT NULL,
	last_activity timestamptz NULL,
	activity_freq float8 NULL
);


ALTER TABLE public.device OWNER TO postgres;

--
-- TOC entry 331 (class 1259 OID 19549)
-- Name: device_auth_data; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.device_auth_data (
    id bigint NOT NULL,
    join_request character varying(200),
    join_accept character varying(200),
    apps_key character varying(32),
    nwks_key character varying(32),
    data_collector_id bigint NOT NULL,
    organization_id bigint NOT NULL,
    app_key_id bigint,
    device_id bigint,
    device_session_id bigint,
    created_at timestamp with time zone,
    join_accept_packet_id bigint,
    join_request_packet_id bigint,
    app_key_hex character varying(32),
    second_join_request character varying(200),
    second_join_request_packet_id bigint
);


ALTER TABLE public.device_auth_data OWNER TO postgres;

--
-- TOC entry 332 (class 1259 OID 19552)
-- Name: device_auth_data_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.device_auth_data_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.device_auth_data_id_seq OWNER TO postgres;

--
-- TOC entry 4496 (class 0 OID 0)
-- Dependencies: 332
-- Name: device_auth_data_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.device_auth_data_id_seq OWNED BY public.device_auth_data.id;


--
-- TOC entry 333 (class 1259 OID 19554)
-- Name: device_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.device_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.device_id_seq OWNER TO postgres;

--
-- TOC entry 4497 (class 0 OID 0)
-- Dependencies: 333
-- Name: device_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.device_id_seq OWNED BY public.device.id;


--
-- TOC entry 391 (class 1259 OID 37866)
-- Name: device_quarantine_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.device_quarantine_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.device_quarantine_id_seq OWNER TO postgres;

--
-- TOC entry 334 (class 1259 OID 19556)
-- Name: device_session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.device_session (
    id bigint NOT NULL,
    may_be_abp boolean,
    reset_counter integer NOT NULL,
    is_confirmed boolean,
    dev_addr character varying(8) NOT NULL,
	up_link_counter int4 NOT NULL DEFAULT 0,
	down_link_counter int4 NOT NULL DEFAULT 0,
	max_down_counter int4 NOT NULL DEFAULT '-1'::integer,
	max_up_counter int4 NOT NULL DEFAULT '-1'::integer,
	total_down_link_packets int8 NOT NULL DEFAULT 0,
	total_up_link_packets int8 NOT NULL DEFAULT 0,
    first_down_timestamp timestamp with time zone,
    first_up_timestamp timestamp with time zone,
    last_down_timestamp timestamp with time zone,
    last_up_timestamp timestamp with time zone,
    device_id bigint,
    organization_id bigint NOT NULL,
    device_auth_data_id bigint,
    last_packet_id bigint,
    median_timestamp double precision,
	last_activity timestamptz NULL,
	connected bool NOT NULL DEFAULT true
);


ALTER TABLE public.device_session OWNER TO postgres;

--
-- TOC entry 335 (class 1259 OID 19559)
-- Name: device_session_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.device_session_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.device_session_id_seq OWNER TO postgres;

--
-- TOC entry 4499 (class 0 OID 0)
-- Dependencies: 335
-- Name: device_session_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.device_session_id_seq OWNED BY public.device_session.id;


--
-- TOC entry 336 (class 1259 OID 19561)
-- Name: device_to_organization; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.device_to_organization (
    device_id bigint NOT NULL,
    organization_id bigint NOT NULL
);


ALTER TABLE public.device_to_organization OWNER TO postgres;

--
-- TOC entry 337 (class 1259 OID 19564)
-- Name: gateway; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.gateway (
    id bigint NOT NULL,
    gw_hex_id character varying(16),
	"name" varchar NULL,
	vendor varchar NULL,
    location_latitude double precision,
    location_longitude double precision,
	data_collector_id bigint NOT NULL,
    organization_id bigint NOT NULL,
    connected boolean DEFAULT true NOT NULL,
    last_activity date NOT NULL,
	activity_freq float8 NULL
);


ALTER TABLE public.gateway OWNER TO postgres;

--
-- TOC entry 338 (class 1259 OID 19567)
-- Name: gateway_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.gateway_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.gateway_id_seq OWNER TO postgres;

--
-- TOC entry 4500 (class 0 OID 0)
-- Dependencies: 338
-- Name: gateway_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.gateway_id_seq OWNED BY public.gateway.id;


--
-- TOC entry 339 (class 1259 OID 19569)
-- Name: gateway_to_device; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.gateway_to_device (
    gateway_id bigint NOT NULL,
    device_id bigint NOT NULL
);


ALTER TABLE public.gateway_to_device OWNER TO postgres;

--
-- TOC entry 340 (class 1259 OID 19572)
-- Name: gateway_to_device_session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.gateway_to_device_session (
    gateway_id bigint NOT NULL,
    device_session_id bigint NOT NULL
);


ALTER TABLE public.gateway_to_device_session OWNER TO postgres;

--
-- TOC entry 399 (class 1259 OID 63649)
-- Name: global_data; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.global_data (
    key character varying(120) NOT NULL,
    value character varying(300) NOT NULL,
    test integer DEFAULT 0
);


ALTER TABLE public.global_data OWNER TO postgres;

--
-- TOC entry 341 (class 1259 OID 19575)
-- Name: iot_user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.iot_user (
    id bigint NOT NULL,
    username character varying(32) NOT NULL,
    full_name character varying(64) NOT NULL,
    email character varying(320) NOT NULL,
    phone character varying(30),
    password character varying(120) NOT NULL,
    organization_id bigint,
    active boolean NOT NULL,
    deleted boolean NOT NULL,
    blocked boolean NOT NULL
);


ALTER TABLE public.iot_user OWNER TO postgres;

--
-- TOC entry 342 (class 1259 OID 19581)
-- Name: iot_user_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.iot_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.iot_user_id_seq OWNER TO postgres;

--
-- TOC entry 4502 (class 0 OID 0)
-- Dependencies: 342
-- Name: iot_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.iot_user_id_seq OWNED BY public.iot_user.id;


--
-- TOC entry 343 (class 1259 OID 19583)
-- Name: login_attempts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.login_attempts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    attempts integer NOT NULL,
    last_attempt timestamp with time zone NOT NULL
);


ALTER TABLE public.login_attempts OWNER TO postgres;

--
-- TOC entry 344 (class 1259 OID 19586)
-- Name: login_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.login_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.login_attempts_id_seq OWNER TO postgres;

--
-- TOC entry 4503 (class 0 OID 0)
-- Dependencies: 344
-- Name: login_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.login_attempts_id_seq OWNED BY public.login_attempts.id;


--
-- TOC entry 345 (class 1259 OID 19588)
-- Name: mqtt_topic; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mqtt_topic (
    id bigint NOT NULL,
    name character varying(120) NOT NULL,
    data_collector_id bigint NOT NULL
);


ALTER TABLE public.mqtt_topic OWNER TO postgres;

--
-- TOC entry 346 (class 1259 OID 19591)
-- Name: mqtt_topic_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.mqtt_topic_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.mqtt_topic_id_seq OWNER TO postgres;

--
-- TOC entry 4504 (class 0 OID 0)
-- Dependencies: 346
-- Name: mqtt_topic_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.mqtt_topic_id_seq OWNED BY public.mqtt_topic.id;


--
-- TOC entry 374 (class 1259 OID 21860)
-- Name: notification; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification (
    id bigint NOT NULL,
    type character varying(20) NOT NULL,
    created_at timestamp with time zone NOT NULL,
    read_at timestamp with time zone,
    alert_id bigint NOT NULL,
    user_id bigint NOT NULL
);


ALTER TABLE public.notification OWNER TO postgres;

--
-- TOC entry 381 (class 1259 OID 24758)
-- Name: notification_additional_email; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_additional_email (
    id bigint NOT NULL,
    email character varying(120) NOT NULL,
    token character varying(500) NOT NULL,
    creation_date timestamp without time zone NOT NULL,
    active boolean NOT NULL,
    user_id bigint NOT NULL
);


ALTER TABLE public.notification_additional_email OWNER TO postgres;

--
-- TOC entry 380 (class 1259 OID 24756)
-- Name: notification_additional_email_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.notification_additional_email_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.notification_additional_email_id_seq OWNER TO postgres;

--
-- TOC entry 4506 (class 0 OID 0)
-- Dependencies: 380
-- Name: notification_additional_email_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.notification_additional_email_id_seq OWNED BY public.notification_additional_email.id;


--
-- TOC entry 383 (class 1259 OID 24794)
-- Name: notification_additional_telephone_number; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_additional_telephone_number (
    id bigint NOT NULL,
    phone character varying(30) NOT NULL,
    token character varying(500) NOT NULL,
    creation_date timestamp without time zone NOT NULL,
    active boolean NOT NULL,
    user_id bigint NOT NULL
);


ALTER TABLE public.notification_additional_telephone_number OWNER TO postgres;

--
-- TOC entry 382 (class 1259 OID 24792)
-- Name: notification_additional_telephone_number_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.notification_additional_telephone_number_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.notification_additional_telephone_number_id_seq OWNER TO postgres;

--
-- TOC entry 4508 (class 0 OID 0)
-- Dependencies: 382
-- Name: notification_additional_telephone_number_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.notification_additional_telephone_number_id_seq OWNED BY public.notification_additional_telephone_number.id;


--
-- TOC entry 369 (class 1259 OID 21751)
-- Name: notification_alert_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_alert_settings (
    user_id bigint NOT NULL,
    high boolean NOT NULL,
    medium boolean NOT NULL,
    low boolean NOT NULL,
    info boolean NOT NULL
);


ALTER TABLE public.notification_alert_settings OWNER TO postgres;

--
-- TOC entry 379 (class 1259 OID 24723)
-- Name: notification_data; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_data (
    user_id bigint NOT NULL,
    last_read timestamp with time zone,
    ws_sid character varying(50)
);


ALTER TABLE public.notification_data OWNER TO postgres;

--
-- TOC entry 370 (class 1259 OID 21761)
-- Name: notification_data_collector_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_data_collector_settings (
    enabled boolean NOT NULL,
    user_id bigint NOT NULL,
    data_collector_id bigint NOT NULL
);


ALTER TABLE public.notification_data_collector_settings OWNER TO postgres;

--
-- TOC entry 373 (class 1259 OID 21858)
-- Name: notification_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.notification_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.notification_id_seq OWNER TO postgres;

--
-- TOC entry 4510 (class 0 OID 0)
-- Dependencies: 373
-- Name: notification_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.notification_id_seq OWNED BY public.notification.id;


--
-- TOC entry 368 (class 1259 OID 21741)
-- Name: notification_preferences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_preferences (
    user_id bigint NOT NULL,
    sms boolean NOT NULL,
    push boolean NOT NULL,
    email boolean NOT NULL
);


ALTER TABLE public.notification_preferences OWNER TO postgres;

--
-- TOC entry 372 (class 1259 OID 21827)
-- Name: notification_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_type (
    id bigint NOT NULL,
    code character varying(20) NOT NULL
);


ALTER TABLE public.notification_type OWNER TO postgres;

--
-- TOC entry 371 (class 1259 OID 21825)
-- Name: notification_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.notification_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.notification_type_id_seq OWNER TO postgres;

--
-- TOC entry 4511 (class 0 OID 0)
-- Dependencies: 371
-- Name: notification_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.notification_type_id_seq OWNED BY public.notification_type.id;


--
-- TOC entry 347 (class 1259 OID 19593)
-- Name: organization; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organization (
    id bigint NOT NULL,
    name character varying(120),
    country character varying(120),
    region character varying(120)
);


ALTER TABLE public.organization OWNER TO postgres;

--
-- TOC entry 348 (class 1259 OID 19596)
-- Name: organization_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.organization_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.organization_id_seq OWNER TO postgres;

--
-- TOC entry 4512 (class 0 OID 0)
-- Dependencies: 348
-- Name: organization_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.organization_id_seq OWNED BY public.organization.id;


--
-- TOC entry 378 (class 1259 OID 24692)
-- Name: packet; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.packet (
    id bigint NOT NULL,
    date timestamp with time zone NOT NULL,
    topic character varying(256),
    data_collector_id bigint NOT NULL,
    organization_id bigint NOT NULL,
    gateway character varying(32),
    tmst bigint,
    chan smallint,
    rfch integer,
    seqn integer,
    opts character varying(20),
    port integer,
    freq double precision,
    stat smallint,
    modu character varying(4),
    datr character varying(50),
    codr character varying(10),
    lsnr double precision,
    rssi integer,
    size integer,
    data character varying(300),
    m_type character varying(20),
    major character varying(10),
    mic character varying(8),
    join_eui character varying(16),
    dev_eui character varying(16),
    dev_nonce integer,
    dev_addr character varying(8),
    adr boolean,
    ack boolean,
    adr_ack_req boolean,
    f_pending boolean,
    class_b boolean,
    f_count integer,
    f_opts character varying(2048),
    f_port integer,
    error character varying(300),
    latitude double precision,
    longitude double precision,
    altitude double precision,
    app_name character varying(100),
    dev_name character varying(100),
	second_join_request varchar(200) NULL,
	gw_name varchar(128) NULL
);


ALTER TABLE public.packet OWNER TO postgres;

--
-- TOC entry 377 (class 1259 OID 24690)
-- Name: packet_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.packet_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.packet_id_seq OWNER TO postgres;

--
-- TOC entry 4514 (class 0 OID 0)
-- Dependencies: 377
-- Name: packet_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.packet_id_seq OWNED BY public.packet.id;


--
-- TOC entry 385 (class 1259 OID 26494)
-- Name: params; Type: TABLE; Schema: public; Owner: postgres
--


CREATE TABLE public.params (
    id integer NOT NULL,
    url_base character varying(120) NOT NULL
);


ALTER TABLE public.params OWNER TO postgres;

--
-- TOC entry 384 (class 1259 OID 26492)
-- Name: params_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.params_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.params_id_seq OWNER TO postgres;

--
-- TOC entry 4516 (class 0 OID 0)
-- Dependencies: 384
-- Name: params_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.params_id_seq OWNED BY public.params.id;


--
-- TOC entry 349 (class 1259 OID 19606)
-- Name: password_reset; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.password_reset (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying(500) NOT NULL,
    creation_date timestamp with time zone NOT NULL,
    active boolean NOT NULL
);


ALTER TABLE public.password_reset OWNER TO postgres;

--
-- TOC entry 350 (class 1259 OID 19612)
-- Name: password_reset_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.password_reset_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.password_reset_id_seq OWNER TO postgres;

--
-- TOC entry 4517 (class 0 OID 0)
-- Dependencies: 350
-- Name: password_reset_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.password_reset_id_seq OWNED BY public.password_reset.id;


--
-- TOC entry 361 (class 1259 OID 21194)
-- Name: policy; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.policy (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    organization_id bigint,
    is_default boolean NOT NULL
);


ALTER TABLE public.policy OWNER TO postgres;

--
-- TOC entry 360 (class 1259 OID 21192)
-- Name: policy_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.policy_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.policy_id_seq OWNER TO postgres;

--
-- TOC entry 4518 (class 0 OID 0)
-- Dependencies: 360
-- Name: policy_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.policy_id_seq OWNED BY public.policy.id;


--
-- TOC entry 363 (class 1259 OID 21207)
-- Name: policy_item; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.policy_item (
    id integer NOT NULL,
    parameters character varying(4096) NOT NULL,
    enabled boolean NOT NULL,
    policy_id bigint NOT NULL,
    alert_type_code character varying(20) NOT NULL
);


ALTER TABLE public.policy_item OWNER TO postgres;

--
-- TOC entry 362 (class 1259 OID 21205)
-- Name: policy_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.policy_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.policy_item_id_seq OWNER TO postgres;

--
-- TOC entry 4519 (class 0 OID 0)
-- Dependencies: 362
-- Name: policy_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.policy_item_id_seq OWNED BY public.policy_item.id;


--
-- TOC entry 365 (class 1259 OID 21300)
-- Name: potential_app_key; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.potential_app_key (
    id bigint NOT NULL,
    device_auth_data_id bigint NOT NULL,
    app_key_hex character varying(32) NOT NULL,
    last_seen timestamp with time zone NOT NULL,
    packet_id bigint,
    organization_id bigint
);


ALTER TABLE public.potential_app_key OWNER TO postgres;

--
-- TOC entry 364 (class 1259 OID 21298)
-- Name: potential_app_key_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.potential_app_key_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.potential_app_key_id_seq OWNER TO postgres;

--
-- TOC entry 4520 (class 0 OID 0)
-- Dependencies: 364
-- Name: potential_app_key_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.potential_app_key_id_seq OWNED BY public.potential_app_key.id;


--
-- TOC entry 395 (class 1259 OID 46186)
-- Name: quarantine; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.quarantine (
    id bigint NOT NULL,
    device_id bigint,
    alert_id bigint NOT NULL,
    since timestamp without time zone NOT NULL,
    resolved_at timestamp without time zone,
    resolved_by_id bigint,
    resolution_comment character varying(1024),
    parameters character varying(4096),
    resolution_reason_id bigint,
    organization_id bigint NOT NULL,
    device_session_id bigint,
    last_checked timestamp without time zone
);


ALTER TABLE public.quarantine OWNER TO postgres;

--
-- TOC entry 393 (class 1259 OID 43668)
-- Name: quarantine_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.quarantine_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.quarantine_id_seq OWNER TO postgres;

--
-- TOC entry 394 (class 1259 OID 46184)
-- Name: quarantine_id_seq1; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.quarantine_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.quarantine_id_seq1 OWNER TO postgres;

--
-- TOC entry 4522 (class 0 OID 0)
-- Dependencies: 394
-- Name: quarantine_id_seq1; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.quarantine_id_seq1 OWNED BY public.quarantine.id;


--
-- TOC entry 392 (class 1259 OID 42917)
-- Name: quarantine_res_reason_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.quarantine_res_reason_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.quarantine_res_reason_seq OWNER TO postgres;

--
-- TOC entry 397 (class 1259 OID 50861)
-- Name: quarantine_resolution_reason; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.quarantine_resolution_reason (
    id bigint NOT NULL,
    type public.quarantineresolutionreasontype,
    name character varying(80) NOT NULL,
    description character varying(200)
);


ALTER TABLE public.quarantine_resolution_reason OWNER TO postgres;

--
-- TOC entry 396 (class 1259 OID 50859)
-- Name: quarantine_resolution_reason_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.quarantine_resolution_reason_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.quarantine_resolution_reason_id_seq OWNER TO postgres;

--
-- TOC entry 4524 (class 0 OID 0)
-- Dependencies: 396
-- Name: quarantine_resolution_reason_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.quarantine_resolution_reason_id_seq OWNED BY public.quarantine_resolution_reason.id;


--
-- TOC entry 351 (class 1259 OID 19614)
-- Name: revoked_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.revoked_tokens (
    id bigint NOT NULL,
    jti character varying(120)
);


ALTER TABLE public.revoked_tokens OWNER TO postgres;

--
-- TOC entry 352 (class 1259 OID 19617)
-- Name: revoked_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.revoked_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.revoked_tokens_id_seq OWNER TO postgres;

--
-- TOC entry 4525 (class 0 OID 0)
-- Dependencies: 352
-- Name: revoked_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.revoked_tokens_id_seq OWNED BY public.revoked_tokens.id;


--
-- TOC entry 353 (class 1259 OID 19619)
-- Name: row_processed; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.row_processed (
    id bigint NOT NULL,
    last_row integer NOT NULL,
    analyzer character varying(20) NOT NULL
);


ALTER TABLE public.row_processed OWNER TO postgres;

--
-- TOC entry 354 (class 1259 OID 19622)
-- Name: row_processed_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.row_processed_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.row_processed_id_seq OWNER TO postgres;

--
-- TOC entry 4526 (class 0 OID 0)
-- Dependencies: 354
-- Name: row_processed_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.row_processed_id_seq OWNED BY public.row_processed.id;


--
-- TOC entry 386 (class 1259 OID 26762)
-- Name: send_email_attempts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.send_email_attempts (
    id integer NOT NULL,
    user_id integer NOT NULL,
    attempts integer NOT NULL
);


ALTER TABLE public.send_email_attempts OWNER TO postgres;

--
-- TOC entry 387 (class 1259 OID 26776)
-- Name: send_email_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.send_email_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.send_email_attempts_id_seq OWNER TO postgres;

--
-- TOC entry 4528 (class 0 OID 0)
-- Dependencies: 387
-- Name: send_email_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.send_email_attempts_id_seq OWNED BY public.send_email_attempts.id;


--
-- TOC entry 359 (class 1259 OID 20931)
-- Name: stats_counters; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.stats_counters (
    id bigint NOT NULL,
    hour timestamp with time zone NOT NULL,
    packets_count bigint NOT NULL,
    joins_count bigint NOT NULL,
    organization_id bigint NOT NULL,
    alerts_count bigint,
    devices_count bigint,
    data_collector_id bigint,
	gateways_count bigint NULL
);


ALTER TABLE public.stats_counters OWNER TO postgres;


--
-- TOC entry 358 (class 1259 OID 20929)
-- Name: stats_counters_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.stats_counters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.stats_counters_id_seq OWNER TO postgres;

--
-- TOC entry 4529 (class 0 OID 0)
-- Dependencies: 358
-- Name: stats_counters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.stats_counters_id_seq OWNED BY public.stats_counters.id;

--
-- TOC entry 355 (class 1259 OID 19624)
-- Name: user_role; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_role (
    id bigint NOT NULL,
    role_name character varying(120) NOT NULL
);


ALTER TABLE public.user_role OWNER TO postgres;

--
-- TOC entry 356 (class 1259 OID 19627)
-- Name: user_role_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.user_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_role_id_seq OWNER TO postgres;

--
-- TOC entry 4531 (class 0 OID 0)
-- Dependencies: 356
-- Name: user_role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.user_role_id_seq OWNED BY public.user_role.id;


--
-- TOC entry 398 (class 1259 OID 59748)
-- Name: user_to_data_collector; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_to_data_collector (
    user_id bigint NOT NULL,
    data_collector_id bigint NOT NULL
);


ALTER TABLE public.user_to_data_collector OWNER TO postgres;

--
-- TOC entry 357 (class 1259 OID 19629)
-- Name: user_to_user_role; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_to_user_role (
    user_id bigint NOT NULL,
    user_role_id bigint NOT NULL
);


ALTER TABLE public.user_to_user_role OWNER TO postgres;

ALTER TABLE ONLY public.account_activation ALTER COLUMN id SET DEFAULT nextval('public.account_activation_id_seq'::regclass);


--
-- TOC entry 4107 (class 2604 OID 19633)
-- Name: alert id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert ALTER COLUMN id SET DEFAULT nextval('public.alert_id_seq'::regclass);


--
-- TOC entry 4109 (class 2604 OID 19634)
-- Name: alert_type id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert_type ALTER COLUMN id SET DEFAULT nextval('public.alert_type_id_seq'::regclass);


--
-- TOC entry 4112 (class 2604 OID 19635)
-- Name: app_key id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_key ALTER COLUMN id SET DEFAULT nextval('public.app_key_id_seq'::regclass);


--
-- TOC entry 4113 (class 2604 OID 19636)
-- Name: change_email_requests id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.change_email_requests ALTER COLUMN id SET DEFAULT nextval('public.change_email_requests_id_seq'::regclass);


--
-- TOC entry 4146 (class 2604 OID 34040)
-- Name: collector_message id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collector_message ALTER COLUMN id SET DEFAULT nextval('public.collector_message_id_seq'::regclass);


--
-- TOC entry 4114 (class 2604 OID 19637)
-- Name: data_collector id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector ALTER COLUMN id SET DEFAULT nextval('public.data_collector_id_seq'::regclass);


--
-- TOC entry 4136 (class 2604 OID 21652)
-- Name: data_collector_log_event id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_log_event ALTER COLUMN id SET DEFAULT nextval('public.data_collector_log_event_id_seq'::regclass);


--
-- TOC entry 4116 (class 2604 OID 19638)
-- Name: data_collector_type id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_type ALTER COLUMN id SET DEFAULT nextval('public.data_collector_type_id_seq'::regclass);


--
-- TOC entry 4117 (class 2604 OID 19640)
-- Name: dev_nonce id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dev_nonce ALTER COLUMN id SET DEFAULT nextval('public.dev_nonce_id_seq'::regclass);


--
-- TOC entry 4118 (class 2604 OID 19641)
-- Name: device id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device ALTER COLUMN id SET DEFAULT nextval('public.device_id_seq'::regclass);


--
-- TOC entry 4120 (class 2604 OID 19642)
-- Name: device_auth_data id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data ALTER COLUMN id SET DEFAULT nextval('public.device_auth_data_id_seq'::regclass);


--
-- TOC entry 4121 (class 2604 OID 19643)
-- Name: device_session id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_session ALTER COLUMN id SET DEFAULT nextval('public.device_session_id_seq'::regclass);


--
-- TOC entry 4122 (class 2604 OID 19644)
-- Name: gateway id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway ALTER COLUMN id SET DEFAULT nextval('public.gateway_id_seq'::regclass);


--
-- TOC entry 4124 (class 2604 OID 19645)
-- Name: iot_user id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.iot_user ALTER COLUMN id SET DEFAULT nextval('public.iot_user_id_seq'::regclass);


--
-- TOC entry 4125 (class 2604 OID 19646)
-- Name: login_attempts id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.login_attempts ALTER COLUMN id SET DEFAULT nextval('public.login_attempts_id_seq'::regclass);


--
-- TOC entry 4126 (class 2604 OID 19647)
-- Name: mqtt_topic id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mqtt_topic ALTER COLUMN id SET DEFAULT nextval('public.mqtt_topic_id_seq'::regclass);


--
-- TOC entry 4138 (class 2604 OID 21863)
-- Name: notification id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification ALTER COLUMN id SET DEFAULT nextval('public.notification_id_seq'::regclass);


--
-- TOC entry 4141 (class 2604 OID 24761)
-- Name: notification_additional_email id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_additional_email ALTER COLUMN id SET DEFAULT nextval('public.notification_additional_email_id_seq'::regclass);


--
-- TOC entry 4142 (class 2604 OID 24797)
-- Name: notification_additional_telephone_number id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_additional_telephone_number ALTER COLUMN id SET DEFAULT nextval('public.notification_additional_telephone_number_id_seq'::regclass);


--
-- TOC entry 4137 (class 2604 OID 21830)
-- Name: notification_type id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_type ALTER COLUMN id SET DEFAULT nextval('public.notification_type_id_seq'::regclass);


--
-- TOC entry 4127 (class 2604 OID 19648)
-- Name: organization id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization ALTER COLUMN id SET DEFAULT nextval('public.organization_id_seq'::regclass);


--
-- TOC entry 4140 (class 2604 OID 24695)
-- Name: packet id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.packet ALTER COLUMN id SET DEFAULT nextval('public.packet_id_seq'::regclass);


--
-- TOC entry 4143 (class 2604 OID 26497)
-- Name: params id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.params ALTER COLUMN id SET DEFAULT nextval('public.params_id_seq'::regclass);


--
-- TOC entry 4128 (class 2604 OID 19650)
-- Name: password_reset id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.password_reset ALTER COLUMN id SET DEFAULT nextval('public.password_reset_id_seq'::regclass);


--
-- TOC entry 4133 (class 2604 OID 21197)
-- Name: policy id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy ALTER COLUMN id SET DEFAULT nextval('public.policy_id_seq'::regclass);


--
-- TOC entry 4134 (class 2604 OID 21210)
-- Name: policy_item id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_item ALTER COLUMN id SET DEFAULT nextval('public.policy_item_id_seq'::regclass);


--
-- TOC entry 4135 (class 2604 OID 21303)
-- Name: potential_app_key id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.potential_app_key ALTER COLUMN id SET DEFAULT nextval('public.potential_app_key_id_seq'::regclass);


--
-- TOC entry 4147 (class 2604 OID 46189)
-- Name: quarantine id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine ALTER COLUMN id SET DEFAULT nextval('public.quarantine_id_seq1'::regclass);


--
-- TOC entry 4148 (class 2604 OID 50864)
-- Name: quarantine_resolution_reason id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine_resolution_reason ALTER COLUMN id SET DEFAULT nextval('public.quarantine_resolution_reason_id_seq'::regclass);


--
-- TOC entry 4129 (class 2604 OID 19651)
-- Name: revoked_tokens id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.revoked_tokens ALTER COLUMN id SET DEFAULT nextval('public.revoked_tokens_id_seq'::regclass);


--
-- TOC entry 4130 (class 2604 OID 19652)
-- Name: row_processed id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.row_processed ALTER COLUMN id SET DEFAULT nextval('public.row_processed_id_seq'::regclass);


--
-- TOC entry 4144 (class 2604 OID 26778)
-- Name: send_email_attempts id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.send_email_attempts ALTER COLUMN id SET DEFAULT nextval('public.send_email_attempts_id_seq'::regclass);


--
-- TOC entry 4132 (class 2604 OID 20934)
-- Name: stats_counters id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stats_counters ALTER COLUMN id SET DEFAULT nextval('public.stats_counters_id_seq'::regclass);


--
-- TOC entry 4131 (class 2604 OID 19653)
-- Name: user_role id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_role ALTER COLUMN id SET DEFAULT nextval('public.user_role_id_seq'::regclass);


--
-- TOC entry 4151 (class 2606 OID 19656)
-- Name: account_activation account_activation_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_activation
    ADD CONSTRAINT account_activation_pkey PRIMARY KEY (id);


--
-- TOC entry 4154 (class 2606 OID 19658)
-- Name: alert alert_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_pkey PRIMARY KEY (id);


--
-- TOC entry 4156 (class 2606 OID 19660)
-- Name: alert_type alert_type_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert_type
    ADD CONSTRAINT alert_type_code_key UNIQUE (code);


--
-- TOC entry 4158 (class 2606 OID 19662)
-- Name: alert_type alert_type_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert_type
    ADD CONSTRAINT alert_type_pkey PRIMARY KEY (id);


--
-- TOC entry 4160 (class 2606 OID 19664)
-- Name: app_key app_key_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_key
    ADD CONSTRAINT app_key_pkey PRIMARY KEY (id);


--
-- TOC entry 4162 (class 2606 OID 19666)
-- Name: change_email_requests change_email_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.change_email_requests
    ADD CONSTRAINT change_email_requests_pkey PRIMARY KEY (id);


--
-- TOC entry 4265 (class 2606 OID 34045)
-- Name: collector_message collector_message_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collector_message
    ADD CONSTRAINT collector_message_pkey PRIMARY KEY (id);


--
-- TOC entry 4231 (class 2606 OID 21657)
-- Name: data_collector_log_event data_collector_log_event_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_log_event
    ADD CONSTRAINT data_collector_log_event_pkey PRIMARY KEY (id);


--
-- TOC entry 4164 (class 2606 OID 19668)
-- Name: data_collector data_collector_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector
    ADD CONSTRAINT data_collector_pkey PRIMARY KEY (id);


--
-- TOC entry 4168 (class 2606 OID 19670)
-- Name: data_collector_to_device data_collector_to_device_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_device
    ADD CONSTRAINT data_collector_to_device_pkey PRIMARY KEY (data_collector_id, device_id);


--
-- TOC entry 4170 (class 2606 OID 19672)
-- Name: data_collector_to_device_session data_collector_to_device_session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_device_session
    ADD CONSTRAINT data_collector_to_device_session_pkey PRIMARY KEY (data_collector_id, device_session_id);


--
-- TOC entry 4276 (class 2606 OID 140816)
-- Name: data_collector_to_gateway data_collector_to_gateway_pk; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_gateway
    ADD CONSTRAINT data_collector_to_gateway_pk PRIMARY KEY (data_collector_id, gateway_id);


--
-- TOC entry 4173 (class 2606 OID 19674)
-- Name: data_collector_type data_collector_type_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_type
    ADD CONSTRAINT data_collector_type_name_key UNIQUE (type);


--
-- TOC entry 4175 (class 2606 OID 19676)
-- Name: data_collector_type data_collector_type_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_type
    ADD CONSTRAINT data_collector_type_pkey PRIMARY KEY (id);


--
-- TOC entry 4177 (class 2606 OID 21048)
-- Name: data_collector_type data_collector_type_un; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_type
    ADD CONSTRAINT data_collector_type_un UNIQUE (name);


--
-- TOC entry 4180 (class 2606 OID 19680)
-- Name: dev_nonce dev_nonce_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dev_nonce
    ADD CONSTRAINT dev_nonce_pkey PRIMARY KEY (id);


--
-- TOC entry 4184 (class 2606 OID 19682)
-- Name: device_auth_data device_auth_data_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_pkey PRIMARY KEY (id);


--
-- TOC entry 4182 (class 2606 OID 19684)
-- Name: device device_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device
    ADD CONSTRAINT device_pkey PRIMARY KEY (id);


--
-- TOC entry 4187 (class 2606 OID 19686)
-- Name: device_session device_session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_session
    ADD CONSTRAINT device_session_pkey PRIMARY KEY (id);


--
-- TOC entry 4189 (class 2606 OID 19688)
-- Name: device_to_organization device_to_organization_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_to_organization
    ADD CONSTRAINT device_to_organization_pkey PRIMARY KEY (device_id, organization_id);


--
-- TOC entry 4191 (class 2606 OID 19690)
-- Name: gateway gateway_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway
    ADD CONSTRAINT gateway_pkey PRIMARY KEY (id);


--
-- TOC entry 4193 (class 2606 OID 19692)
-- Name: gateway_to_device gateway_to_device_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway_to_device
    ADD CONSTRAINT gateway_to_device_pkey PRIMARY KEY (gateway_id, device_id);


--
-- TOC entry 4195 (class 2606 OID 19694)
-- Name: gateway_to_device_session gateway_to_device_session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway_to_device_session
    ADD CONSTRAINT gateway_to_device_session_pkey PRIMARY KEY (gateway_id, device_session_id);


--
-- TOC entry 4273 (class 2606 OID 63653)
-- Name: global_data global_data_pk; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.global_data
    ADD CONSTRAINT global_data_pk PRIMARY KEY (key);


--
-- TOC entry 4197 (class 2606 OID 26914)
-- Name: iot_user iot_user_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.iot_user
    ADD CONSTRAINT iot_user_email_key UNIQUE (email);


--
-- TOC entry 4199 (class 2606 OID 19698)
-- Name: iot_user iot_user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.iot_user
    ADD CONSTRAINT iot_user_pkey PRIMARY KEY (id);


--
-- TOC entry 4202 (class 2606 OID 19700)
-- Name: login_attempts login_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.login_attempts
    ADD CONSTRAINT login_attempts_pkey PRIMARY KEY (id);


--
-- TOC entry 4204 (class 2606 OID 19702)
-- Name: mqtt_topic mqtt_topic_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mqtt_topic
    ADD CONSTRAINT mqtt_topic_pkey PRIMARY KEY (id);


--
-- TOC entry 4253 (class 2606 OID 24766)
-- Name: notification_additional_email notification_additional_email_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_additional_email
    ADD CONSTRAINT notification_additional_email_pkey PRIMARY KEY (id);


--
-- TOC entry 4255 (class 2606 OID 24802)
-- Name: notification_additional_telephone_number notification_additional_telephone_number_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_additional_telephone_number
    ADD CONSTRAINT notification_additional_telephone_number_pkey PRIMARY KEY (id);


--
-- TOC entry 4235 (class 2606 OID 21755)
-- Name: notification_alert_settings notification_alert_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_alert_settings
    ADD CONSTRAINT notification_alert_settings_pkey PRIMARY KEY (user_id);


--
-- TOC entry 4237 (class 2606 OID 21765)
-- Name: notification_data_collector_settings notification_data_collector_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_data_collector_settings
    ADD CONSTRAINT notification_data_collector_settings_pkey PRIMARY KEY (user_id, data_collector_id);


--
-- TOC entry 4251 (class 2606 OID 24727)
-- Name: notification_data notification_data_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_data
    ADD CONSTRAINT notification_data_pkey PRIMARY KEY (user_id);


--
-- TOC entry 4243 (class 2606 OID 21865)
-- Name: notification notification_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification
    ADD CONSTRAINT notification_pkey PRIMARY KEY (id);


--
-- TOC entry 4233 (class 2606 OID 21745)
-- Name: notification_preferences notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_pkey PRIMARY KEY (user_id);


--
-- TOC entry 4239 (class 2606 OID 21834)
-- Name: notification_type notification_type_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_type
    ADD CONSTRAINT notification_type_code_key UNIQUE (code);


--
-- TOC entry 4241 (class 2606 OID 21832)
-- Name: notification_type notification_type_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_type
    ADD CONSTRAINT notification_type_pkey PRIMARY KEY (id);


--
-- TOC entry 4206 (class 2606 OID 19704)
-- Name: organization organization_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization
    ADD CONSTRAINT organization_name_key UNIQUE (name);


--
-- TOC entry 4208 (class 2606 OID 19706)
-- Name: organization organization_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization
    ADD CONSTRAINT organization_pkey PRIMARY KEY (id);


--
-- TOC entry 4249 (class 2606 OID 24700)
-- Name: packet packet_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.packet
    ADD CONSTRAINT packet_pkey PRIMARY KEY (id);


--
-- TOC entry 4257 (class 2606 OID 26499)
-- Name: params params_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.params
    ADD CONSTRAINT params_pkey PRIMARY KEY (id);


--
-- TOC entry 4210 (class 2606 OID 19710)
-- Name: password_reset password_reset_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.password_reset
    ADD CONSTRAINT password_reset_pkey PRIMARY KEY (id);


--
-- TOC entry 4226 (class 2606 OID 21215)
-- Name: policy_item policy_item_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_item
    ADD CONSTRAINT policy_item_pkey PRIMARY KEY (id);


--
-- TOC entry 4224 (class 2606 OID 21199)
-- Name: policy policy_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy
    ADD CONSTRAINT policy_pkey PRIMARY KEY (id);


--
-- TOC entry 4228 (class 2606 OID 21305)
-- Name: potential_app_key potential_app_key_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.potential_app_key
    ADD CONSTRAINT potential_app_key_pkey PRIMARY KEY (id);


--
-- TOC entry 4267 (class 2606 OID 46194)
-- Name: quarantine quarantine_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_pkey PRIMARY KEY (id);


--
-- TOC entry 4269 (class 2606 OID 50866)
-- Name: quarantine_resolution_reason quarantine_resolution_reason_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine_resolution_reason
    ADD CONSTRAINT quarantine_resolution_reason_pkey PRIMARY KEY (id);


--
-- TOC entry 4212 (class 2606 OID 19712)
-- Name: revoked_tokens revoked_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.revoked_tokens
    ADD CONSTRAINT revoked_tokens_pkey PRIMARY KEY (id);


--
-- TOC entry 4214 (class 2606 OID 19714)
-- Name: row_processed row_processed_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.row_processed
    ADD CONSTRAINT row_processed_pkey PRIMARY KEY (id);


--
-- TOC entry 4259 (class 2606 OID 26766)
-- Name: send_email_attempts send_email_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.send_email_attempts
    ADD CONSTRAINT send_email_attempts_pkey PRIMARY KEY (id);


--
-- TOC entry 4222 (class 2606 OID 20936)
-- Name: stats_counters stats_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stats_counters
    ADD CONSTRAINT stats_counters_pkey PRIMARY KEY (id);


--
-- TOC entry 4216 (class 2606 OID 19716)
-- Name: user_role user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_pkey PRIMARY KEY (id);


--
-- TOC entry 4218 (class 2606 OID 19718)
-- Name: user_role user_role_role_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_role_name_key UNIQUE (role_name);


--
-- TOC entry 4271 (class 2606 OID 59752)
-- Name: user_to_data_collector user_to_data_collector_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_to_data_collector
    ADD CONSTRAINT user_to_data_collector_pkey PRIMARY KEY (user_id, data_collector_id);


--
-- TOC entry 4220 (class 2606 OID 19720)
-- Name: user_to_user_role user_to_user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_to_user_role
    ADD CONSTRAINT user_to_user_role_pkey PRIMARY KEY (user_id, user_role_id);


--
-- TOC entry 4152 (class 1259 OID 21034)
-- Name: alert_created_at_data_collector_id_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX alert_created_at_data_collector_id_index ON public.alert USING btree (created_at DESC NULLS LAST, data_collector_id);


--
-- TOC entry 4262 (class 1259 OID 76339)
-- Name: collector_message_data_collector_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX collector_message_data_collector_id_idx ON public.collector_message USING btree (data_collector_id);


--
-- TOC entry 4263 (class 1259 OID 76338)
-- Name: collector_message_packet_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX collector_message_packet_id_idx ON public.collector_message USING btree (packet_id);


--
-- TOC entry 4229 (class 1259 OID 63400)
-- Name: data_collector_log_event_data_collector_id_multiidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX data_collector_log_event_data_collector_id_multiidx ON public.data_collector_log_event USING btree (data_collector_id, created_at);


--
-- TOC entry 4274 (class 1259 OID 140827)
-- Name: data_collector_to_gateway_data_collector_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX data_collector_to_gateway_data_collector_id_idx ON public.data_collector_to_gateway USING btree (data_collector_id, gateway_id);


--
-- TOC entry 4185 (class 1259 OID 21693)
-- Name: dc_devaddr_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX dc_devaddr_index ON public.device_session USING btree (dev_addr, id);


--
-- TOC entry 4171 (class 1259 OID 21692)
-- Name: dc_ds_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX dc_ds_index ON public.data_collector_to_device_session USING btree (device_session_id, data_collector_id);


--
-- TOC entry 4165 (class 1259 OID 63675)
-- Name: dc_idx_createdat; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX dc_idx_createdat ON public.data_collector USING btree (created_at DESC);


--
-- TOC entry 4178 (class 1259 OID 100200)
-- Name: dev_nonce_device_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX dev_nonce_device_id_idx ON public.dev_nonce USING btree (device_id, dev_nonce);


--
-- TOC entry 4166 (class 1259 OID 21122)
-- Name: fki_data_collector_policy_id_fkey; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX fki_data_collector_policy_id_fkey ON public.data_collector USING btree (policy_id);


--
-- TOC entry 4200 (class 1259 OID 26900)
-- Name: ix_iot_user_username; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ix_iot_user_username ON public.iot_user USING btree (username);


--
-- TOC entry 4246 (class 1259 OID 24721)
-- Name: packet_date_data_collector_id_dev_eui_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX packet_date_data_collector_id_dev_eui_index ON public.packet USING btree (date, data_collector_id, dev_eui);


--
-- TOC entry 4247 (class 1259 OID 24720)
-- Name: packet_date_organization_id_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX packet_date_organization_id_index ON public.packet USING btree (date DESC, organization_id DESC);


--
-- TOC entry 4277 (class 2606 OID 19722)
-- Name: account_activation account_activation_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_activation
    ADD CONSTRAINT account_activation_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4278 (class 2606 OID 19727)
-- Name: alert alert_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4283 (class 2606 OID 76465)
-- Name: alert alert_device_auth_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_device_auth_id_fkey FOREIGN KEY (device_auth_id) REFERENCES public.device_auth_data(id) ON DELETE CASCADE;


--
-- TOC entry 4284 (class 2606 OID 79474)
-- Name: alert alert_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4279 (class 2606 OID 19742)
-- Name: alert alert_device_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_device_session_id_fkey FOREIGN KEY (device_session_id) REFERENCES public.device_session(id);


--
-- TOC entry 4280 (class 2606 OID 19747)
-- Name: alert alert_gateway_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_gateway_id_fkey FOREIGN KEY (gateway_id) REFERENCES public.gateway(id);


--
-- TOC entry 4281 (class 2606 OID 19757)
-- Name: alert alert_resolved_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_resolved_by_id_fkey FOREIGN KEY (resolved_by_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4282 (class 2606 OID 19762)
-- Name: alert alert_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alert
    ADD CONSTRAINT alert_type_fkey FOREIGN KEY (type) REFERENCES public.alert_type(code);


--
-- TOC entry 4285 (class 2606 OID 19767)
-- Name: app_key app_key_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_key
    ADD CONSTRAINT app_key_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4286 (class 2606 OID 19772)
-- Name: change_email_requests change_email_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.change_email_requests
    ADD CONSTRAINT change_email_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4344 (class 2606 OID 76358)
-- Name: collector_message collector_message_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collector_message
    ADD CONSTRAINT collector_message_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4345 (class 2606 OID 76363)
-- Name: collector_message collector_message_packet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.collector_message
    ADD CONSTRAINT collector_message_packet_id_fkey FOREIGN KEY (packet_id) REFERENCES public.packet(id) ON DELETE CASCADE;


--
-- TOC entry 4287 (class 2606 OID 19777)
-- Name: data_collector data_collector_data_collector_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector
    ADD CONSTRAINT data_collector_data_collector_type_id_fkey FOREIGN KEY (data_collector_type_id) REFERENCES public.data_collector_type(id);


--
-- TOC entry 4324 (class 2606 OID 21658)
-- Name: data_collector_log_event data_collector_log_event_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_log_event
    ADD CONSTRAINT data_collector_log_event_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4325 (class 2606 OID 21663)
-- Name: data_collector_log_event data_collector_log_event_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_log_event
    ADD CONSTRAINT data_collector_log_event_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4288 (class 2606 OID 19782)
-- Name: data_collector data_collector_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector
    ADD CONSTRAINT data_collector_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4289 (class 2606 OID 19787)
-- Name: data_collector_to_device data_collector_to_device_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_device
    ADD CONSTRAINT data_collector_to_device_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4290 (class 2606 OID 79443)
-- Name: data_collector_to_device data_collector_to_device_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_device
    ADD CONSTRAINT data_collector_to_device_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4291 (class 2606 OID 19797)
-- Name: data_collector_to_device_session data_collector_to_device_session_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_device_session
    ADD CONSTRAINT data_collector_to_device_session_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4292 (class 2606 OID 79535)
-- Name: data_collector_to_device_session data_collector_to_device_session_device_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_device_session
    ADD CONSTRAINT data_collector_to_device_session_device_session_id_fkey FOREIGN KEY (device_session_id) REFERENCES public.device_session(id) ON DELETE CASCADE;


--
-- TOC entry 4354 (class 2606 OID 140817)
-- Name: data_collector_to_gateway data_collector_to_gateway_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_gateway
    ADD CONSTRAINT data_collector_to_gateway_fk FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4355 (class 2606 OID 140822)
-- Name: data_collector_to_gateway data_collector_to_gateway_fk_1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.data_collector_to_gateway
    ADD CONSTRAINT data_collector_to_gateway_fk_1 FOREIGN KEY (gateway_id) REFERENCES public.gateway(id);


--
-- TOC entry 4293 (class 2606 OID 79454)
-- Name: dev_nonce dev_nonce_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dev_nonce
    ADD CONSTRAINT dev_nonce_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4297 (class 2606 OID 76368)
-- Name: device_auth_data device_auth_data_app_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_app_key_id_fkey FOREIGN KEY (app_key_id) REFERENCES public.app_key(id);


--
-- TOC entry 4298 (class 2606 OID 76373)
-- Name: device_auth_data device_auth_data_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4296 (class 2606 OID 79424)
-- Name: device_auth_data device_auth_data_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4299 (class 2606 OID 76383)
-- Name: device_auth_data device_auth_data_device_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_device_session_id_fkey FOREIGN KEY (device_session_id) REFERENCES public.device_session(id);


--
-- TOC entry 4300 (class 2606 OID 76388)
-- Name: device_auth_data device_auth_data_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4295 (class 2606 OID 76783)
-- Name: device_auth_data device_auth_data_second_join_request_packet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_auth_data
    ADD CONSTRAINT device_auth_data_second_join_request_packet_id_fkey FOREIGN KEY (join_request_packet_id) REFERENCES public.packet(id) ON DELETE CASCADE;


--
-- TOC entry 4294 (class 2606 OID 19852)
-- Name: device device_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device
    ADD CONSTRAINT device_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4302 (class 2606 OID 76905)
-- Name: device_session device_session_device_auth_data_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_session
    ADD CONSTRAINT device_session_device_auth_data_id_fkey FOREIGN KEY (device_auth_data_id) REFERENCES public.device_auth_data(id) ON DELETE CASCADE;


--
-- TOC entry 4303 (class 2606 OID 79407)
-- Name: device_session device_session_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_session
    ADD CONSTRAINT device_session_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4301 (class 2606 OID 19872)
-- Name: device_session device_session_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_session
    ADD CONSTRAINT device_session_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4305 (class 2606 OID 79429)
-- Name: device_to_organization device_to_organization_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_to_organization
    ADD CONSTRAINT device_to_organization_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4304 (class 2606 OID 19882)
-- Name: device_to_organization device_to_organization_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_to_organization
    ADD CONSTRAINT device_to_organization_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4306 (class 2606 OID 19892)
-- Name: gateway gateway_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway
    ADD CONSTRAINT gateway_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4308 (class 2606 OID 79469)
-- Name: gateway_to_device gateway_to_device_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway_to_device
    ADD CONSTRAINT gateway_to_device_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4307 (class 2606 OID 19902)
-- Name: gateway_to_device gateway_to_device_gateway_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway_to_device
    ADD CONSTRAINT gateway_to_device_gateway_id_fkey FOREIGN KEY (gateway_id) REFERENCES public.gateway(id);


--
-- TOC entry 4310 (class 2606 OID 79524)
-- Name: gateway_to_device_session gateway_to_device_session_device_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway_to_device_session
    ADD CONSTRAINT gateway_to_device_session_device_session_id_fkey FOREIGN KEY (device_session_id) REFERENCES public.device_session(id) ON DELETE CASCADE;


--
-- TOC entry 4309 (class 2606 OID 19912)
-- Name: gateway_to_device_session gateway_to_device_session_gateway_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.gateway_to_device_session
    ADD CONSTRAINT gateway_to_device_session_gateway_id_fkey FOREIGN KEY (gateway_id) REFERENCES public.gateway(id);


--
-- TOC entry 4311 (class 2606 OID 19917)
-- Name: iot_user iot_user_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.iot_user
    ADD CONSTRAINT iot_user_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4312 (class 2606 OID 19922)
-- Name: login_attempts login_attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.login_attempts
    ADD CONSTRAINT login_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4313 (class 2606 OID 19927)
-- Name: mqtt_topic mqtt_topic_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mqtt_topic
    ADD CONSTRAINT mqtt_topic_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4337 (class 2606 OID 24767)
-- Name: notification_additional_email notification_additional_email_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_additional_email
    ADD CONSTRAINT notification_additional_email_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4338 (class 2606 OID 24803)
-- Name: notification_additional_telephone_number notification_additional_telephone_number_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_additional_telephone_number
    ADD CONSTRAINT notification_additional_telephone_number_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4330 (class 2606 OID 76471)
-- Name: notification notification_alert_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification
    ADD CONSTRAINT notification_alert_id_fkey FOREIGN KEY (alert_id) REFERENCES public.alert(id) ON DELETE CASCADE;


--
-- TOC entry 4327 (class 2606 OID 21756)
-- Name: notification_alert_settings notification_alert_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_alert_settings
    ADD CONSTRAINT notification_alert_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4329 (class 2606 OID 21771)
-- Name: notification_data_collector_settings notification_data_collector_settings_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_data_collector_settings
    ADD CONSTRAINT notification_data_collector_settings_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4328 (class 2606 OID 21766)
-- Name: notification_data_collector_settings notification_data_collector_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_data_collector_settings
    ADD CONSTRAINT notification_data_collector_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4336 (class 2606 OID 24728)
-- Name: notification_data notification_data_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_data
    ADD CONSTRAINT notification_data_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4326 (class 2606 OID 21746)
-- Name: notification_preferences notification_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4331 (class 2606 OID 21866)
-- Name: notification notification_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification
    ADD CONSTRAINT notification_type_fkey FOREIGN KEY (type) REFERENCES public.notification_type(code);


--
-- TOC entry 4332 (class 2606 OID 21876)
-- Name: notification notification_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification
    ADD CONSTRAINT notification_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4334 (class 2606 OID 24701)
-- Name: packet packet_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.packet
    ADD CONSTRAINT packet_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4335 (class 2606 OID 24706)
-- Name: packet packet_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.packet
    ADD CONSTRAINT packet_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4314 (class 2606 OID 19942)
-- Name: password_reset password_reset_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.password_reset
    ADD CONSTRAINT password_reset_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4321 (class 2606 OID 21221)
-- Name: policy_item policy_item_alert_type_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_item
    ADD CONSTRAINT policy_item_alert_type_code_fkey FOREIGN KEY (alert_type_code) REFERENCES public.alert_type(code);


--
-- TOC entry 4320 (class 2606 OID 21216)
-- Name: policy_item policy_item_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy_item
    ADD CONSTRAINT policy_item_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.policy(id) ON DELETE CASCADE;


--
-- TOC entry 4319 (class 2606 OID 21200)
-- Name: policy policy_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.policy
    ADD CONSTRAINT policy_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4322 (class 2606 OID 76458)
-- Name: potential_app_key potential_app_key_device_auth_data_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.potential_app_key
    ADD CONSTRAINT potential_app_key_device_auth_data_id_fkey FOREIGN KEY (device_auth_data_id) REFERENCES public.device_auth_data(id) ON DELETE CASCADE;


--
-- TOC entry 4323 (class 2606 OID 21316)
-- Name: potential_app_key potential_app_key_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.potential_app_key
    ADD CONSTRAINT potential_app_key_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4347 (class 2606 OID 76920)
-- Name: quarantine quarantine_alert_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_alert_id_fkey FOREIGN KEY (alert_id) REFERENCES public.alert(id) ON DELETE CASCADE;


--
-- TOC entry 4351 (class 2606 OID 79509)
-- Name: quarantine quarantine_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.device(id) ON DELETE CASCADE;


--
-- TOC entry 4350 (class 2606 OID 46366)
-- Name: quarantine quarantine_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_fk FOREIGN KEY (device_session_id) REFERENCES public.device_session(id);


--
-- TOC entry 4348 (class 2606 OID 46210)
-- Name: quarantine quarantine_organization_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_organization_fk FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4346 (class 2606 OID 55999)
-- Name: quarantine quarantine_res_reason_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_res_reason_fk FOREIGN KEY (resolution_reason_id) REFERENCES public.quarantine_resolution_reason(id);


--
-- TOC entry 4349 (class 2606 OID 46220)
-- Name: quarantine quarantine_resolved_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.quarantine
    ADD CONSTRAINT quarantine_resolved_by_id_fkey FOREIGN KEY (resolved_by_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4339 (class 2606 OID 26767)
-- Name: send_email_attempts send_email_attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.send_email_attempts
    ADD CONSTRAINT send_email_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4318 (class 2606 OID 55702)
-- Name: stats_counters stats_counters_data_collector_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stats_counters
    ADD CONSTRAINT stats_counters_data_collector_id FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);

--
-- TOC entry 4317 (class 2606 OID 20937)
-- Name: stats_counters stats_counters_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stats_counters
    ADD CONSTRAINT stats_counters_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);


--
-- TOC entry 4353 (class 2606 OID 59762)
-- Name: user_to_data_collector user_to_data_collector_data_collector_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_to_data_collector
    ADD CONSTRAINT user_to_data_collector_data_collector_id_fkey FOREIGN KEY (data_collector_id) REFERENCES public.data_collector(id);


--
-- TOC entry 4352 (class 2606 OID 59757)
-- Name: user_to_data_collector user_to_data_collector_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_to_data_collector
    ADD CONSTRAINT user_to_data_collector_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4315 (class 2606 OID 19947)
-- Name: user_to_user_role user_to_user_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_to_user_role
    ADD CONSTRAINT user_to_user_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.iot_user(id);


--
-- TOC entry 4316 (class 2606 OID 19952)
-- Name: user_to_user_role user_to_user_role_user_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_to_user_role
    ADD CONSTRAINT user_to_user_role_user_role_id_fkey FOREIGN KEY (user_role_id) REFERENCES public.user_role(id);


CREATE SEQUENCE public.device_vendor_prefix_id_seq;

CREATE TABLE public.device_vendor_prefix (
        id bigint PRIMARY KEY DEFAULT nextval('public.device_vendor_prefix_id_seq'),
        prefix varchar(9) NOT NULL,
        vendor varchar(512) NOT NULL
);

ALTER SEQUENCE public.device_vendor_prefix_id_seq
	OWNED BY public.device_vendor_prefix.id;

--
-- TOC entry 4483 (class 0 OID 0)
-- Dependencies: 8
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: postgres
--

GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO PUBLIC;

-- Completed on 2020-02-13 12:45:50 -03

--
-- PostgreSQL database dump complete
--

-- Changes from version 1.2.0

ALTER TABLE public.gateway ALTER column gw_hex_id type varchar(100);


-- Changes from version 1.3.0

begin transaction;

CREATE TABLE public.tag (
	id serial8 NOT NULL,
	organization_id int8 NOT NULL,
	"name" varchar NOT NULL,
	color char(8) NOT NULL,
	CONSTRAINT tag_pk PRIMARY KEY (id)
);

CREATE TABLE public.device_tag (
	device_id int8 NOT NULL,
	tag_id int8 NOT NULL
);

ALTER TABLE public.device_tag 
    ADD CONSTRAINT device_tag_pk PRIMARY KEY (device_id,tag_id);

ALTER TABLE ONLY public.device_tag
	ADD CONSTRAINT device_tag_fk_1 FOREIGN KEY (device_id) REFERENCES public.device(id);

ALTER TABLE ONLY public.device_tag
	ADD CONSTRAINT device_tag_fk_2 FOREIGN KEY (tag_id) REFERENCES public.tag(id);

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id);
    

CREATE TABLE public.gateway_tag (
	gateway_id int8 NOT NULL,
	tag_id int8 NOT NULL
);

ALTER TABLE public.gateway_tag 
    ADD CONSTRAINT gateway_tag_pk PRIMARY KEY (gateway_id,tag_id);

ALTER TABLE ONLY public.gateway_tag
	ADD CONSTRAINT gateway_tag_fk_1 FOREIGN KEY (gateway_id) REFERENCES public.gateway(id);

ALTER TABLE ONLY public.gateway_tag
	ADD CONSTRAINT gateway_tag_fk_2 FOREIGN KEY (tag_id) REFERENCES public.tag(id);

commit;

CREATE UNIQUE INDEX device_vendor_prefix_prefix_idx ON public.device_vendor_prefix (prefix);

-- Feature/resource_usage

ALTER TABLE public.device ADD npackets_up int8 NULL DEFAULT 0;
ALTER TABLE public.device ADD npackets_down int8 NULL DEFAULT 0;
ALTER TABLE public.device ADD npackets_lost int8 NULL DEFAULT 0;

ALTER TABLE public.gateway ADD npackets_up int8 NULL DEFAULT 0;
ALTER TABLE public.gateway ADD npackets_down int8 NULL DEFAULT 0;
ALTER TABLE public.gateway ADD npackets_lost int8 NULL DEFAULT 0;
