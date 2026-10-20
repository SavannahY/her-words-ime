#!/usr/bin/env python3
"""Minimal, version-checked ctypes bindings for Squirrel's public librime API.

Loading this module does not load native libraries. Rime(...) loads the supplied
Squirrel bundle and its Lua plugin. No third-party Python packages are required.
"""

import ctypes as C
import os

API_REFERENCE = "https://github.com/rime/librime/blob/1.16.0/src/rime_api.h"


class Traits(C.Structure):
    _fields_ = [
        ("data_size", C.c_int),
        ("shared_data_dir", C.c_char_p),
        ("user_data_dir", C.c_char_p),
        ("distribution_name", C.c_char_p),
        ("distribution_code_name", C.c_char_p),
        ("distribution_version", C.c_char_p),
        ("app_name", C.c_char_p),
        ("modules", C.POINTER(C.c_char_p)),
        ("min_log_level", C.c_int),
        ("log_dir", C.c_char_p),
        ("prebuilt_data_dir", C.c_char_p),
        ("staging_dir", C.c_char_p),
    ]


class Composition(C.Structure):
    _fields_ = [(name, C.c_int) for name in
                ("length", "cursor_pos", "sel_start", "sel_end")] + [
                    ("preedit", C.c_char_p)]


class Candidate(C.Structure):
    _fields_ = [("text", C.c_char_p), ("comment", C.c_char_p),
                ("reserved", C.c_void_p)]


class Menu(C.Structure):
    _fields_ = [(name, C.c_int) for name in
                ("page_size", "page_no", "is_last_page",
                 "highlighted_candidate_index", "num_candidates")] + [
        ("candidates", C.POINTER(Candidate)), ("select_keys", C.c_char_p)]


class Context(C.Structure):
    _fields_ = [("data_size", C.c_int), ("composition", Composition),
                ("menu", Menu), ("commit_text_preview", C.c_char_p),
                ("select_labels", C.POINTER(C.c_char_p))]


class Commit(C.Structure):
    _fields_ = [("data_size", C.c_int), ("text", C.c_char_p)]


class CandidateIterator(C.Structure):
    _fields_ = [("ptr", C.c_void_p), ("index", C.c_int),
                ("candidate", Candidate)]


# RimeApi is an append-only, self-versioned structure. Unknown functions are
# intentionally left as void pointers; only the public functions used below are
# converted to callable ctypes prototypes after checking data_size.
API_NAMES = """
setup set_notification_handler initialize finalize
start_maintenance is_maintenance_mode join_maintenance_thread
deployer_initialize prebuild deploy deploy_schema deploy_config_file
sync_user_data create_session find_session destroy_session
cleanup_stale_sessions cleanup_all_sessions process_key commit_composition
clear_composition get_commit free_commit get_context free_context get_status
free_status set_option get_option set_property get_property get_schema_list
free_schema_list get_current_schema select_schema schema_open config_open
config_close config_get_bool config_get_int config_get_double config_get_string
config_get_cstring config_update_signature config_begin_map config_next config_end
simulate_key_sequence register_module find_module run_task get_shared_data_dir
get_user_data_dir get_sync_dir get_user_id get_user_data_sync_dir config_init
config_load_string config_set_bool config_set_int config_set_double
config_set_string config_get_item config_set_item config_clear config_create_list
config_create_map config_list_size config_begin_list get_input get_caret_pos
select_candidate get_version set_caret_pos select_candidate_on_current_page
candidate_list_begin candidate_list_next candidate_list_end user_config_open
candidate_list_from_index get_prebuilt_data_dir get_staging_dir commit_proto
context_proto status_proto get_state_label delete_candidate
delete_candidate_on_current_page get_state_label_abbreviated set_input
get_shared_data_dir_s get_user_data_dir_s get_prebuilt_data_dir_s
get_staging_dir_s get_sync_dir_s highlight_candidate
highlight_candidate_on_current_page change_page
""".split()


class Api(C.Structure):
    _fields_ = [("data_size", C.c_int)] + [
        (name, C.c_void_p) for name in API_NAMES]


def initialized(struct_type):
    result = struct_type()
    result.data_size = C.sizeof(struct_type) - C.sizeof(C.c_int)
    return result


def decode(value):
    return (value or b"").decode("utf-8")


class Rime:
    def __init__(self, app, shared, user):
        self.lib = C.CDLL(str(app / "Contents/Frameworks/librime.1.dylib"),
                          mode=C.RTLD_GLOBAL)
        self.plugin = C.CDLL(str(app / "Contents/Frameworks/rime-plugins/librime-lua.dylib"),
                             mode=C.RTLD_GLOBAL)
        self.lib.rime_get_api.argtypes = []
        self.lib.rime_get_api.restype = C.POINTER(Api)
        self.raw = self.lib.rime_get_api().contents
        self.functions = {}
        self.modules = (C.c_char_p * 3)(b"default", b"lua", None)
        self.traits = initialized(Traits)
        self.traits.shared_data_dir = os.fsencode(shared)
        self.traits.user_data_dir = os.fsencode(user)
        self.traits.distribution_name = b"Her Words Integration Test"
        self.traits.distribution_code_name = b"her_words_test"
        self.traits.distribution_version = b"1.0"
        self.traits.app_name = b"rime.her_words_test"
        self.traits.modules = self.modules
        self.traits.min_log_level = 2
        self.traits.log_dir = os.fsencode(user)
        self.started = False
        self.bind("setup", None, C.POINTER(Traits))(C.byref(self.traits))
        self.bind("initialize", None, C.POINTER(Traits))(C.byref(self.traits))
        self.started = True

    def bind(self, name, result, *arguments):
        if name not in self.functions:
            offset = getattr(Api, name).offset
            if offset + C.sizeof(C.c_void_p) > self.raw.data_size + C.sizeof(C.c_int):
                raise RuntimeError("librime does not provide API function " + name)
            address = getattr(self.raw, name)
            if not address:
                raise RuntimeError("librime API function is NULL: " + name)
            self.functions[name] = C.CFUNCTYPE(result, *arguments)(address)
        return self.functions[name]

    def version(self):
        return decode(self.bind("get_version", C.c_char_p)())

    def deploy(self):
        self.bind("start_maintenance", C.c_int, C.c_int)(1)
        self.bind("join_maintenance_thread", None)()

    def session(self, schema):
        sid = self.bind("create_session", C.c_size_t)()
        if not sid:
            raise RuntimeError("librime could not create a session")
        if not self.bind("select_schema", C.c_int, C.c_size_t, C.c_char_p)(
                sid, schema.encode()):
            self.destroy(sid)
            raise RuntimeError("librime could not select schema " + schema)
        self.bind("set_option", None, C.c_size_t, C.c_char_p, C.c_int)(
            sid, b"ascii_mode", 0)
        return sid

    def destroy(self, sid):
        self.bind("destroy_session", C.c_int, C.c_size_t)(sid)

    def key(self, sid, char):
        return bool(self.bind("process_key", C.c_int, C.c_size_t,
                              C.c_int, C.c_int)(sid, ord(char), 0))

    def commit(self, sid):
        result = initialized(Commit)
        if not self.bind("get_commit", C.c_int, C.c_size_t,
                         C.POINTER(Commit))(sid, C.byref(result)):
            return ""
        try:
            return decode(result.text)
        finally:
            self.bind("free_commit", C.c_int, C.POINTER(Commit))(C.byref(result))

    def context(self, sid):
        result = initialized(Context)
        if not self.bind("get_context", C.c_int, C.c_size_t,
                         C.POINTER(Context))(sid, C.byref(result)):
            return {"preedit": "", "pageCandidates": [], "preview": ""}
        try:
            return {"preedit": decode(result.composition.preedit),
                    "pageCandidates": [decode(result.menu.candidates[i].text)
                                       for i in range(result.menu.num_candidates)],
                    "preview": decode(result.commit_text_preview)}
        finally:
            self.bind("free_context", C.c_int, C.POINTER(Context))(C.byref(result))

    def candidates(self, sid, limit):
        iterator = CandidateIterator()
        result = []
        begin = self.bind("candidate_list_begin", C.c_int, C.c_size_t,
                          C.POINTER(CandidateIterator))
        advance = self.bind("candidate_list_next", C.c_int,
                            C.POINTER(CandidateIterator))
        end = self.bind("candidate_list_end", None, C.POINTER(CandidateIterator))
        if not begin(sid, C.byref(iterator)):
            return result, False
        try:
            while advance(C.byref(iterator)):
                if len(result) >= limit:
                    return result, True
                result.append(decode(iterator.candidate.text))
            return result, False
        finally:
            end(C.byref(iterator))

    def close(self):
        if self.started:
            self.bind("finalize", None)()
            self.started = False
