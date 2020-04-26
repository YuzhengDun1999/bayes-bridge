cimport cython
from libc.math cimport exp as exp_c
from libc.math cimport fabs, pow, log, sqrt, sin, floor
from libc.math cimport INFINITY, M_PI
import math
import random
cdef double MAX_EXP_ARG = 709  # ~ log(2 ** 1024)
ctypedef double (*rand_generator)()


cdef double exp(double x):
    if x > MAX_EXP_ARG:
        val = INFINITY
    elif x < - MAX_EXP_ARG:
        val = 0.
    else:
        val = exp_c(x)
    return val


@cython.cdivision(True)
cdef double sinc(double x):
    cdef double x_sq
    if fabs(x) < .01:
        x_sq = x * x
        val = 1. - x_sq / 6. * (1 - x_sq / 20.)
            # Taylor approximation with an error bounded by 2e-16
    else:
        val = sin(x) / x
    return val


cdef double python_builtin_next_double():
    return <double>random.random()


cdef class ExpTiltedStableDist():
    cdef rand_generator next_double

    def __init__(self, seed=None):
        random.seed(seed)
        self.next_double = python_builtin_next_double

    def get_state(self):
        return random.getstate()

    def set_state(self, state):
        random.setstate(state)

    def rv(self, char_exponent, tilt, method=None):
        """
        Generate a random variable from a stable distribution with
            characteristic exponent =  char_exponent < 1
            skewness = 1
            scale = cos(char_exponent * pi / 2) ** (1 / char_exponent)
            location = 0
            exponential tilting = tilt
        (The density p(x) is tilted by exp(- tilt * x).)

        The cost of the divide-conquer algorithm increases as a function of
        'tilt ** char_exp'. While the cost of double-rejection algorithm is
        bounded, the divide-conquer algorithm is simpler and faster for small
        'tilt ** char_exp'.

        References:
        -----------
        Implementation is mostly based on the algorithm descriptions in
            'Sampling Exponentially Tilted Stable Distributions' by Hofert (2011)
        Ideas behind and details on the double-rejection sampling is better
        described in
            'Random variate generation for exponentially and polynomially tilted
            stable distributions' by Devroye (2009)
        """

        if method is None:
            # Choose a likely faster method.
            divide_conquer_cost = pow(tilt, char_exponent)
            double_rejection_cost = 5.0
                # The relative costs are implementation & architecture dependent.
            if divide_conquer_cost < double_rejection_cost:
                method = 'divide-conquer'
            else:
                method = 'double-rejection'

        if method == 'divide-conquer':
            X = self.sample_by_divide_and_conquer(char_exponent, tilt)
        elif method == 'double-rejection':
            X = self.sample_by_double_rejection(char_exponent, tilt)
        else:
            raise NotImplementedError()

        return X

    cdef double sample_by_divide_and_conquer(self, double char_exp, double lam):
        cdef double X, c
        cdef long partition_size = max(1, <long>floor(pow(lam, char_exp)))
        X = 0.
        c = pow(1. / partition_size, 1. / char_exp)
        for i in range(partition_size):
            X += self.sample_divided_rv(char_exp, lam, c)
        return X

    cdef double sample_divided_rv(self, double char_exp, double lam, double c):
        cdef bint accepted = False
        while not accepted:
            S = c * self.sample_non_tilted_rv(char_exp)
            accept_prob = exp(- lam * S)
            accepted = (self.next_double() < accept_prob)
        return S

    cdef double sample_non_tilted_rv(self, double char_exp):
        cdef double V, E, S
        V = self.next_double()
        E = - log(self.next_double())
        S = pow(
            self.zolotarev_function(M_PI * V, char_exp) / E
        , (1. - char_exp) / char_exp)
        return S

    cdef double sample_by_double_rejection(self, double char_exp, double lam):

        cdef double b, lam_alpha, gamma, xi, psi, \
            U, Z, z, X, N, E, a, m, delta, log_accept_prob

        # Pre-compute a bunch of quantities.
        b = (1. - char_exp) / char_exp
        lam_alpha = pow(lam, char_exp)
        gamma = lam_alpha * char_exp * (1. - char_exp)
        xi = (1. + sqrt(2. * gamma) * (2. + sqrt(.5 * M_PI))) / M_PI
        psi = sqrt(gamma) * (2. + sqrt(.5 * M_PI)) * exp(- gamma * M_PI * M_PI / 8.) / sqrt(M_PI)

        # Start double-rejection sampling.
        cdef bint accepted = False
        while not accepted:
            U, Z, z = self.sample_aux_rv(xi, psi, gamma, char_exp, lam_alpha)
            X, N, E, a, m, delta = \
                self.sample_reference_rv(U, char_exp, lam_alpha, b, z)
            log_accept_prob = \
                self.compute_log_accept_prob(X, N, E, a, m, char_exp, lam_alpha, b, delta)
            accepted = (log_accept_prob > log(Z))

        return pow(X, -b)

    cdef sample_aux_rv(self,
            double xi, double psi, double gamma,
            double char_exp, double lam_alpha
        ):
        """
        Samples an auxiliary random variable for the double-rejection algorithm.
        Returns:
            U : auxiliary random variable for the double-rejection algorithm
            Z : uniform random variable independent of U, X
            z : scalar quantity used later
        """
        cdef double U, Z, z, accept_prob
        cdef bint accepted = False
        while not accepted:
            U = self.sample_aux2_rv(xi, psi, gamma)
            if U > M_PI:
                accept_prob = 0.
            else:
                zeta = sqrt(self.zolotarev_pdf_exponentiated(U, char_exp))
                z = 1. / (1. - pow(1. + char_exp * zeta / sqrt(gamma), -1. / char_exp))
                accept_prob = self.compute_aux2_accept_prob(
                    U, xi, psi, zeta, z, lam_alpha, gamma)
            if accept_prob == 0.:
                accepted = False
            else:
                Z = self.next_double() / accept_prob
                accepted = (U < M_PI and Z <= 1.)

        return U, Z, z

    cdef double sample_aux2_rv(self,
            double xi, double psi, double gamma):
        """
        Sample the 2nd level auxiliary random variable (i.e. the additional
        auxiliary random variable used to sample the auxilary variable for
        double-rejection algorithm.)
        """

        w1 = sqrt(.5 * M_PI / gamma) * xi
        w2 = 2. * sqrt(M_PI) * psi
        w3 = xi * M_PI
        V = self.next_double()
        if gamma >= 1:
            if V < w1 / (w1 + w2):
                U = fabs(self.rand_standard_normal()) / sqrt(gamma)
            else:
                W = self.next_double()
                U = M_PI * (1. - W * W)
        else:
            W = self.next_double()
            if V < w3 / (w2 + w3):
                U = M_PI * W
            else:
                U = M_PI * (1. - W * W)

        return U

    cdef double compute_aux2_accept_prob(self,
            double U, double xi, double psi, double zeta, double z,
            double lam_alpha, double gamma
        ):
        inverse_accept_prob = M_PI * exp(-lam_alpha * (1. - 1. / (zeta * zeta))) \
              / ((1. + sqrt(.5 * M_PI)) * sqrt(gamma) / zeta + z)
        d = 0.
        if U >= 0. and gamma >= 1:
            d += xi * exp(-gamma * U * U / 2.)
        if U > 0. and U < M_PI:
            d += psi / sqrt(M_PI - U)
        if U >= 0. and U <= M_PI and gamma < 1.:
            d += xi
        inverse_accept_prob *= d
        accept_prob = 1 / inverse_accept_prob
        return accept_prob

    cdef sample_reference_rv(self,
            double U, double char_exp, double lam_alpha, double b, double z):
        """
        Generate a sample from the reference (augmented) distribution conditional
        on U for the double-rejection algorithm

        Returns:
        --------
            X : random variable from the reference distribution
            N, E : random variables used later for computing the acceptance prob
            a, m, delta: scalar quantities used later
        """
        a = self.zolotarev_function(U, char_exp)
        m = pow(b / a, char_exp) * lam_alpha
        delta = sqrt(m * char_exp / a)
        a1 = delta * sqrt(.5 * M_PI)
        a3 = z / a
        s = a1 + delta + a3
        V2 = self.next_double()
        N = 0.
        E = 0.
        if V2 < a1 / s:
            N = self.rand_standard_normal()
            X = m - delta * fabs(N)
        elif V2 < (a1 + delta) / s:
            X = m + delta * self.next_double()
        else:
            E = - log(self.next_double())
            X = m + delta + E * a3
        return X, N, E, a, m, delta

    cdef double compute_log_accept_prob(self,
            double X, double N, double E, double a, double m,
            double char_exp, double lam_alpha, double b, double delta
        ):
        if X < 0:
            log_accept_prob = - INFINITY
        else:
            log_accept_prob = - (
                a * (X - m)
                + exp((1. / char_exp) * log(lam_alpha) - b * log(m)) * (pow(m / X, b) - 1.)
            )
            if X < m:
                log_accept_prob += N * N / 2.
            elif X > m + delta:
                log_accept_prob += E

        return log_accept_prob

    cdef double zolotarev_pdf_exponentiated(self, double x, double char_exp):
        """
        Evaluates a function proportional to a power of the Zolotarev density.
        """
        cdef double denominator, numerator
        denominator = pow(sinc(char_exp * x), char_exp) \
                      * pow(sinc((1. - char_exp) * x), (1. - char_exp))
        numerator = sinc(x)
        return numerator / denominator

    cdef double zolotarev_function(self, double x, double char_exp):
        cdef double val = pow(
            pow((1. - char_exp) * sinc((1. - char_exp) * x), (1. - char_exp))
            * pow(char_exp * sinc(char_exp * x), char_exp)
            / sinc(x)
        , 1. / (1. - char_exp))
        return val

    cdef double rand_standard_normal(self):
        # Sample via Polar method
        cdef double X, Y, sq_norm
        sq_norm = 1. # Placeholder value to pass through the first loop
        while sq_norm >= 1. or sq_norm == 0.:
          X = 2. * self.next_double() - 1.
          Y = 2. * self.next_double() - 1.
          sq_norm = X * X + Y * Y
        return sqrt(-2. * log(sq_norm) / sq_norm) * Y
