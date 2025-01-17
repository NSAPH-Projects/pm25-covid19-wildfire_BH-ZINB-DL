library(abind)
library(tidyr)
library(splines)
library(pscl)
library(rjags)
library(sf)

remove(list = ls())

load.module('glm')

### Data Loading

setwd("~/Github/covid_wildfire")
source("src/Utilities.R")
source("src/bayes/model.R")
source("src/bayes/bayes_fun.R")
dff <- load.data()
dff$FIPS <- as.numeric(as.character(dff$FIPS))

dff$pm_counter <- dff$pm25
dff$pm_counter[dff$pm_wildfire != 0] <- dff$pm25_history[dff$pm_wildfire != 0]

# for mobility
# dff <- subset(dff, !(FIPS %in% c(6051, 41023, 41025, 41037, 41063, 53013)))

# for outliers_
# dff <- subset(dff, !(FIPS %in% c(6009, 6051)))

### Data Cleaning

# Create Exposure Matrix
X_long <- data.frame(date_num = dff$date_num, FIPS = dff$FIPS, pm25 = dff$pm25)
X_tmp <- tidyr::spread(X_long, date_num, pm25)
X <- X_tmp[order(X_tmp$FIPS),]

# PM counterfactual
X_counter_long <- data.frame(date_num = dff$date_num, FIPS = dff$FIPS, pm25 = dff$pm_counter)
X_counter_tmp <- tidyr::spread(X_counter_long, date_num, pm25)
X_counter <- X_counter_tmp[order(X_counter_tmp$FIPS),]

# Population Size
pop_long <- data.frame(FIPS = dff$FIPS, pop = dff$population)
pop_tmp <- pop_long[!duplicated(pop_long$FIPS),]
pop <- pop_tmp[order(pop_tmp$FIPS),]

# Create Outcome Matrices
Y_long_cases <- data.frame(date_num = dff$date_num, FIPS = dff$FIPS, cases = dff$cases)
Y_tmp_cases <- tidyr::spread(Y_long_cases, date_num, cases)
Y_cases <- Y_tmp_cases[order(Y_tmp_cases$FIPS),]

Y_long_death <- data.frame(date_num = dff$date_num, FIPS = dff$FIPS, death = dff$death)
Y_tmp_death <- tidyr::spread(Y_long_death, date_num, death)
Y_deaths <- Y_tmp_death[order(Y_tmp_death$FIPS),]

# Create Covariate Array
Z_long <- data.frame(FIPS = dff$FIPS, date_num = dff$date_num, tmmx = dff$tmmx, 
                     rmax = dff$rmax, dayofweek = dff$dayofweek)
Z_long <- Z_long[order(Z_long$date_num, Z_long$FIPS),]

# calendar day, tmmx, and rmax are fitted with natural spline basis
Z_bs <- with(Z_long, data.frame(FIPS = FIPS, date_num = date_num, 
                                tmmx = ns(tmmx, 2), rmax = ns(rmax, 2),
                                model.matrix(~ dayofweek)[,-1]))

Z_tmp <- Z_bs[Z_bs$date_num == min(dff$date_num),]
Z <- Z_tmp[order(Z_tmp$FIPS),]

# split array by date_num
for (i in (min(dff$date_num) + 1):max(dff$date_num)){
  
  Z_tmp <- Z_bs[Z_bs$date_num == i,]
  Z_tmp <- Z_tmp[order(Z_tmp$FIPS),]
  
  Z <- abind(Z, Z_tmp, along = 3)

}

total_cases <- rowSums(Y_cases[,-1], na.rm = TRUE)
total_deaths <- rowSums(Y_deaths[,-1], na.rm = TRUE)

### Begin Bayesian analysis

# Data Dimensions
l <- 28 # desired max lag
n <- nrow(X)
m <- ncol(X) - 1
o <- 6
p <- dim(Z)[2] - 2 # covariate dimension
q <- 6 # number of spline basis functions for PM2.5 + 1 for intercept

# hyperparameters
a <- rep(0, q)
b <- rep(0, p)
c <- rep(0, o)
R <- diag(1e-10, q)
S <- diag(1e-10, p)
V <- diag(1e-10, o)
sig <- rep(1e5, q) # scaled gamma/wishart scale

U <- matrix(ns(c(l:0), df = q, intercept = TRUE), nrow = l+1, ncol = q)  # natural spline basis constraint
W <- matrix(ns(min(dff$date_num):max(dff$date_num), df = o), ncol = o)

# get initial values for MCMC
gm_cases <- pm_model(dff, lags=0:l, df.pm = q, df.date=o, df.tmmx=2, df.rmax=2, cause = "cases", fullDist = TRUE, model = "Constrained", mobility = FALSE)
gm_deaths <- pm_model(dff, lags=0:l, df.pm = q, df.date=o, df.tmmx=2, df.rmax=2, cause = "deaths", fullDist = TRUE, model = "Constrained", mobility = FALSE)

### Cases Model
  
# JAGS call
jagsDat_cases <- list(n = n, m = m, l = l, o = o, p = p, q = q, 
                      X = X[,-1], Y = Y_cases[,-1], Z = Z[,-c(1:2),],
                      U = U, W = W, pop = pop[,-1], X_counter = X_counter[,-1],
                      a = a, b = b, c = c, R = R, S = S, V = V, sig = sig)

jmod_cases <- jags.model(file = "src/bayes/dlag_fit.jags", data = jagsDat_cases, n.chains = 1, n.adapt = 20000, quiet = FALSE,
                         inits = function() list("mu" = gm_cases$mu.init, "xi" = gm_cases$xi.init, "phi" = 1,
                                                 "beta" = gm_cases$beta.init, "delta" = gm_cases$delta.init))
mcmc_cases <- coda.samples(jmod_cases,n.iter = 100000, thin = 100, na.rm = TRUE,
                           variable.names = c("beta",  "xi", "mu", "tau", "theta", "eta", 
                                              "phi", "psi", "sigma", "lambda", "rho"))

# check mixing
pdf(file = "~/Dropbox/Projects/Wildfires/Output/bayes/trace_cases_28.pdf")
plot(mcmc_cases)
dev.off()

# check autocorrelation
pdf(file = "~/Dropbox/Projects/Wildfires/Output/bayes/acf_cases_28.pdf")
for(i in 1:ncol(mcmc_cases[[1]]))
  acf(mcmc_cases[[1]][,i], main = colnames(mcmc_cases[[1]])[i])
dev.off()

save(mcmc_cases, file = "~/Dropbox/Projects/Wildfires/Output/bayes/mcmc_cases_28.RData")
  
### Deaths Model

# JAGS call
jagsDat_deaths <- list(n = n, m = m, l = l, o = o, p = p, q = q, 
                      X = X[,-1], Y = Y_deaths[,-1], Z = Z[,-c(1:2),], 
                      U = U, W = W, pop = pop[,-1], X_counter = X_counter[,-1], 
                      a = a, b = b, c = c, R = R, S = S, V = V, sig = sig)

jmod_deaths <- jags.model(file = "src/bayes/dlag_fit.jags", data = jagsDat_deaths, n.chains = 1, n.adapt = 100000, quiet = FALSE,
                          inits = function() list("mu" = gm_deaths$mu.init, "xi" = gm_deaths$xi.init, "phi" = 1,
                                                  "beta" = gm_deaths$beta.init, "delta" = gm_deaths$delta.init))
mcmc_deaths <- coda.samples(jmod_deaths, n.iter = 100000, thin = 100, na.rm = TRUE,
                            variable.names = c("beta",  "xi", "mu", "tau", "theta", "eta",
                                               "phi", "psi", "sigma", "lambda", "rho"))

# check mixing
pdf(file = "~/Dropbox/Projects/Wildfires/Output/bayes/trace_deaths_28.pdf")
plot(mcmc_deaths)
dev.off()

# check autocorrelation
pdf(file = "~/Dropbox/Projects/Wildfires/Output/bayes/acf_deaths_28.pdf")
for(i in 1:ncol(mcmc_deaths[[1]]))
  acf(mcmc_deaths[[1]][,i], main = colnames(mcmc_deaths[[1]])[i])
dev.off()

save(mcmc_deaths, file = "~/Dropbox/Projects/Wildfires/Output/bayes/mcmc_deaths_28.RData")
