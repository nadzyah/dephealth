//! The serving tier. Forecasts and risk scores are computed offline on a
//! schedule and this half only reads the stored results, so no request here
//! computes a score.

pub mod config;
pub mod db;
pub mod dto;
pub mod error;
pub mod http;
pub mod manifest;
