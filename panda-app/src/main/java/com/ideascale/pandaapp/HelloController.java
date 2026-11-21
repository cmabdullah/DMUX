package com.ideascale.pandaapp;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class HelloController {

    private final JdbcTemplate jdbc;

    @Value("${DB_NAME:panda}")
    private String dbName;

    public HelloController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping("/")
    public Map<String, String> hello() {
        String database;
        try {
            jdbc.queryForObject("SELECT 1", Integer.class);
            database = "connected";
        } catch (Exception e) {
            database = "error: " + e.getMessage();
        }
        Map<String, String> body = new LinkedHashMap<>();
        body.put("message", "Hello, World");
        body.put("database", database);
        body.put("db_name", dbName);
        body.put("db_user_source", "openbao:secret/panda/db");
        return body;
    }
}
