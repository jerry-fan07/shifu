# Shifu - Design Spec #

Shifu watches you work.

**Date:** 2026-07-17
**Summary:** Create a minimalist program or application that watches your screen throughout the day while taking as minimally intensive resources as possible. Recorded data is processed for analysis on things such as productivity, storing new information/knowledge for review, and identifying opportunities for automation or use of AI help.

## 0. Setup

Decide on what exactly is the setup of Shifu, what languages it should be written in, how the architecture should be setup to best achieve the goals.

## 1. Minimal Resource Use

The user should not feel the presence of the screen information being captured at all, and the application should be designed to be as minimally resource intensive as possible to acquire the information. This could mean that a picture is taken every time the screen is changed, only text is captured, or other ways (Rust) to minimize resource usage to not hinder the user.

## 2. Analysis

### Productivity Analysis
The analyzed data should be used to track exactly how much time the user is spending on certain things, such as work, entertainment, socializing/networking, learning, etc.

An additional feature for this could be to have the ability to enable a work mode, in which the program can detect whether a user is not working and lightly remind the user (a subtle glow pulse on the screen every few minutes)

### Storing Information for Review
New or learned information and knowledge should be stored from the captured data analyzed and become accessible for the user to review.

For this there should a minimalist database/folder of some sort that the user can pull from to review in a spaced repetition manner.

### Identifying Efficiency Opportunities
The application should be able to identify possible opportunities for automation from the analyzed data, or opportunities for AI to streamline your work.
