library(abind)
library(tidyr)
library(MASS)
library(imputeTS)
library(pscl)
library(rjags)
library(mvtnorm)
library(smooth)
library(splines)
library(reshape2)
library(ggpubr)

remove(list = ls())

setwd("~/Github/covid_wildfire")
source("src/bayes/bayes_fun.R")

load.module("glm")

### Data Creation

# dimensions
n <- 100 # number of counties
m <- 250 # days
l <- 14 # lag days
p <- 4 # number of spline basis functions for calendar days
q <- 5 # number of spline basis functions for lagged PM2.5

lags <- 0:l
time <- 0:(m - 1)

# set seed for replication
set.seed(42)

pop <- floor(runif(n, 10000, 1000000)) # population offset
X <- t(replicate(n, 8 + arima.sim(list(ma = 0.5), n = m))) #PM2.5 measurements
Z <- ns(time, df = p) # calendar days
colnames(Z) <- paste("Z", 1:p, sep = "")

# random effects
alpha <- rnorm(n, -10, 1.3) # random intercept
eta <- log((l - lags) + 1)*sin((l - lags)*pi/4)/10
theta <- t(replicate(n, rnorm(l + 1, eta, sqrt(0.01)))) # lagged PM2.5 coefficients
psi <- plogis(10 - log(pop))

save(theta, "~/Dropbox/Projects/Wildfires/Output/simulation/true_theta.csv")

# overdispersion
phi <- 1.5

Y <- matrix(NA, n, m) # initialize outcome matrix

# generate responses
for (j in 1:m) {

  lin_pred <- rep(NA, n)

  for (i in 1:n)
    lin_pred[i] <- c(X[i,max(1,j-l):j, drop = FALSE]%*%theta[i,max(1,l-j+2):(l+1)])

  A <- rbinom(n, 1, psi)
  lambda <- exp(alpha + time[j]*sin(pi*time[j]/100)/1000 + log(pop) + lin_pred)
  pi <- phi/(phi + (1 - A)*lambda)

  Y[,j] <- rnbinom(n, phi, pi)

}

# hyperparameters
a <- rep(0, l+1)
b <- rep(0, p)
R <- diag(1e-10, l+1)
S <- diag(1e-10, p)
sig <- rep(1e5, l+1)

### Unconstrained Bayesian Model

Y.long <- melt(data.frame(id = 1:n, Y), variable.name = "time", value.name = "Y", id.vars = "id")
Y.long$time <- as.numeric(sub('.', '', Y.long$time))

X.long <- melt(data.frame(id = 1:n, X), variable.name = "time", value.name = "X", id.vars = "id")
X.long$time <- as.numeric(sub('.', '', X.long$time))

long.tmp1 <- merge(Y.long, X.long, by = c("id", "time"))
long.tmp2 <- merge(long.tmp1, cbind(id = 1:n, log.pop = log(pop)), by = "id")
long <- merge(long.tmp2, cbind(time = 1:m, Z = Z), by = "time")
long <- long[order(long$id, long$time),]
long$time <- long$time - 1

lag.names = c()

for (i in l:0) {
  new.var = paste0("l", i)
  lag.names = c(lag.names, new.var)
  long = long %>% 
    dplyr::group_by(id) %>% 
    dplyr::mutate(!!new.var := dplyr::lag(!!as.name("X"), n = i, default = NA))
  long <- data.frame(long)
}

dat <- long[order(long$time, long$id),]
fmla_un <- paste("Y ~ ", paste("Z", 1:p, collapse = " + ", sep = ""), " + ", 
                 paste("l", l:0, collapse = " + ", sep = ""), " | 1", sep = "")

fit_un <- zeroinfl(as.formula(fmla_un), dist = "negbin", link = "logit", data = dat, offset = log.pop, na.action = na.exclude)

# JAGS call
jagsDat_un <- list(n = n, m = m, l = l, p = p, 
                   X = X, Y = Y, Z = Z, pop = pop, 
                   a = a, b = b, R = R, S = S, sig = sig)

mu.init <- fit_un$coefficients$count[1]
xi.init <- fit_un$coefficients$count[grep("Z", names(fit_un$coefficients$count))]
eta.init <- fit_un$coefficients$count[grep("l", names(fit_un$coefficients$count))]
phi.init <- 1

jmod_un <- jags.model(file = "src/bayes/dlag_unconstrained.jags", data = jagsDat_un, 
                      n.chains = 1, n.adapt = 10000, quiet = FALSE,
                      inits = function() list("phi" = phi.init, "eta" = eta.init, 
                                              "mu" = mu.init, "xi" = xi.init))
mcmc_sim_un <- coda.samples(jmod_un, variable.names = c("theta", "eta", "sigma", "xi", "mu", "tau", "phi", "psi"), 
                            n.iter = 50000, thin = 50, na.rm = TRUE)

# check mixing
pdf(file = "~/Dropbox/Projects/Wildfires/Output/simulation/sim_trace_un.pdf")
plot(mcmc_sim_un)
dev.off()

save(mcmc_sim_un, file = "~/Dropbox/Projects/Wildfires/Output/simulation/mcmc_sim_un.RData")

### Constrained Bayesian Model

# construct new covariate arrays
X.l <- dat[,grep("l", colnames(dat))][,-1]
U <- as.matrix(ns(c(l:0), df = q, intercept = TRUE)) # natural spline basis matrix

spmat <- as.matrix(X.l) %*% as.matrix(U)
colnames(spmat) <- paste("U", 1:q, sep = "")
dat_c <- data.frame(dat, spmat)

fmla_c <- paste("Y ~ ", paste("Z", 1:p, collapse = " + ", sep = ""), " + ", 
                paste("U", 1:q, collapse = " + ", sep = ""), " | 1", sep = "")

fit_c <- zeroinfl(as.formula(fmla_c), dist = "negbin", link = "logit", data = dat_c, offset = log.pop, na.action = na.exclude)

# hyperparameter change
a <- rep(0, q)
R <- diag(1e-10, q)
sig <- rep(1e5, q)

# JAGS call
jagsDat_c <- list(n = n, m = m, l = l, p = p, q = q,
                  X = X, Y = Y, Z = Z, U = U, pop = pop,
                  a = a, b = b, R = R, S = S, sig = sig)

mu.init <- fit_c$coefficients$count[1]
xi.init <- fit_c$coefficients$count[grep("Z", names(fit_c$coefficients$count))]
delta.init <- fit_c$coefficients$count[grep("U", names(fit_c$coefficients$count))]
phi.init <- 1

jmod_c <- jags.model(file = "src/bayes/dlag_constrained.jags", data = jagsDat_c,
                     n.chains = 1, n.adapt = 10000, quiet = FALSE,
                     inits = function() list("phi" = phi.init, "delta" = delta.init, 
                                             "mu" = mu.init, "xi" = xi.init))
mcmc_sim_c <- coda.samples(jmod_c, variable.names = c("theta", "eta", "delta", "sigma", "xi", "mu", "tau", "phi", "psi"), 
                           n.iter = 50000, thin = 100, na.rm = TRUE)

# check mixing
pdf(file = "~/Dropbox/Projects/Wildfires/Output/simulation/sim_trace_c.pdf")
plot(mcmc_sim_c)
dev.off()

save(mcmc_sim_c, file = "~/Dropbox/Projects/Wildfires/Output/simulation/mcmc_sim_c.RData")

### plot lag effects

load("~/Dropbox/Projects/Wildfires/Output/simulation/mcmc_sim_c.RData")
load("~/Dropbox/Projects/Wildfires/Output/simulation/mcmc_sim_un.RData")
load("~/Dropbox/Projects/Wildfires/Output/simulation/true_theta.RData")

label <- rep(NA,100)
label[c(1,25,50,75,100)] <- letters[1:5]

plot_list <- lapply(c(1,25,50,75,100), function(i, ...){
  
  theta.c <- mcmc_sim_c[[1]][,grep(paste0("theta\\[",i,","), colnames(mcmc_sim_c[[1]]))]
  theta.c.mu <- colMeans(theta.c)
  theta.c.cp <- apply(theta.c, 2, hpd)
  gmat.c <- data.frame(theta.c.mu, t(theta.c.cp), l - lags, model = "Constrained")
  names(gmat.c) <- c("theta", "hpd_l", "hpd_u", "lags", "model")
  
  theta.un <- mcmc_sim_un[[1]][,grep(paste0("theta\\[",i,","), colnames(mcmc_sim_un[[1]]))]
  theta.un.mu <- colMeans(theta.un)
  theta.un.cp <- apply(theta.un, 2, hpd)
  gmat.un <- data.frame(theta.un.mu, t(theta.un.cp), x = l - lags, model = "Unconstrained")
  names(gmat.un) <- names(gmat.c)
  
  gmat.tru <- data.frame(theta[i,], theta[i,], theta[i,], x = l - lags, model = "True Value")
  names(gmat.tru) <- names(gmat.c)
  
  gmat <- rbind(gmat.c, gmat.un, gmat.tru)
  gmat$model <- factor(gmat$model, levels = c("Unconstrained", "Constrained", "True Value"))
  
  ggplot(aes(x = lags, y = theta, color = model, ymax = hpd_u, ymin = hpd_l), data = gmat) + 
    geom_pointrange(position = position_dodge(width = 0.5)) +
    theme(plot.title = element_text(hjust = 0.5, face = "bold")) +
    labs(title = paste(label[i], "County", i), x = "Lag Days", y = "Coefficient Value", color = "Model") + 
    scale_color_manual(values = c("Unconstrained" = hue_pal()(2)[2], "Constrained" = hue_pal()(2)[1], "True Value" = "black"))
  
})

eta.c <- mcmc_sim_c[[1]][,paste("eta[",1:15,"]", sep = "")]
eta.c.mu <- colMeans(eta.c)
eta.c.cp <- apply(eta.c, 2, hpd)

gmat.c <- data.frame(eta.c.mu, t(eta.c.cp), l - lags, model = "Constrained")
names(gmat.c) <- c("eta", "hpd_l", "hpd_u", "lags", "model")

eta.un <- mcmc_sim_un[[1]][,paste0("eta[",1:15,"]")]
eta.un.mu <- colMeans(eta.un)
eta.un.cp <- apply(eta.un, 2, hpd)

gmat.un <- data.frame(eta.un.mu, t(eta.un.cp), l - lags, model = "Unconstrained")
names(gmat.un) <- names(gmat.c)

gmat.tru <- data.frame(eta, eta, eta, x = l - lags, model = "True Value")
names(gmat.tru) <- names(gmat.c)

gmat <- rbind(gmat.c, gmat.un, gmat.tru)
gmat$model <- factor(gmat$model, levels = c("Unconstrained", "Constrained", "True Value"))

eta_plot <- ggplot() + 
  geom_pointrange(aes(x = lags, y = eta, color = model, ymax = hpd_u, ymin = hpd_l), data = gmat, position = position_dodge(width=0.5)) +
  labs(title = "f Combined Counties", x = "Lag Days", y = "Coefficient Value", color = "Model") +
  theme(plot.title = element_text(hjust = 0.5, face = "bold")) +
  scale_color_manual(values = c("Unconstrained" = hue_pal()(2)[2], "Constrained" = hue_pal()(2)[1], "True Value" = "black"))

pdf("~/Dropbox/Projects/Wildfires/Output/simulation/sim_fit.pdf")  
ggarrange(plot_list[[1]], plot_list[[2]], plot_list[[3]], plot_list[[4]], plot_list[[5]], eta_plot, ncol=2, nrow=3, common.legend = TRUE, legend="bottom")
dev.off()

### create equivalent table to the plot

load("~/Dropbox/Projects/Wildfires/Output/simulation/mcmc_sim_un.RData")
load("~/Dropbox/Projects/Wildfires/Output/simulation/mcmc_sim_c.RData")

eta.un <- mcmc_sim_un[[1]][,paste0("eta[",1:15,"]")]
eta.c <- mcmc_sim_c[[1]][,paste0("eta[",1:15,"]")]
sigma <- mcmc_sim_un[[1]][,paste0("sigma[",1:15,"]")]

est_out <- round(rbind(rev(eta), rev(colMeans(eta.un)), rev(colMeans(eta.c)), rev(colMeans(sigma))), 3)
rownames(est_out) <- c("Truth", "Unconstrained Bayes", "Constrained Bayes", "Theta Variance")

write.csv(est_out, file = "~/Dropbox/Projects/Wildfires/Output/simulation/sim_out.csv")
