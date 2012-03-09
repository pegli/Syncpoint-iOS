# Syncpoint Document Schema ##

## Session ##
type            depends on auth type, e.g. "session-fb"
oauth_creds     {"consumer_key": , "consumer_secret": , "token_secret" : , "token": }
state           "new" | "active"
session         {"user_id": server-assigned user ID, "control_database": control db name}

...plus custom properties defined by auth type, such as:
fb_access_token Facebook token string


## Channel ##

type            "channel"
state           "new" | "ready"
owner_id        User ID from session document
default         boolean [optional?]
name            string
cloud_database  string

## Subscription ##

type            "subscription"
state           "active"
channel_id      ID of corresponding channel document
owner_id        User ID from session document

## Installation ##

type            "installation"
state           "created"
local_db_name   Name of corresponding local database
subscription_id ID of corresponding subscription document
channel_id      ID of corresponding channel document
session_id      ID of session document
owner_id        User ID from session document
