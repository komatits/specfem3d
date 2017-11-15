!=====================================================================
!
!               S p e c f e m 3 D  V e r s i o n  3 . 0
!               ---------------------------------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                              CNRS, France
!                       and Princeton University, USA
!                 (there are currently many more authors!)
!                           (c) October 2017
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================

  subroutine compute_kernels()

! kernel calculations
! see e.g. Tromp et al. (2005) for elastic calculation
! and Morency et al. (2009) for poroelastic calculation

  use specfem_par
  use specfem_par_elastic
  use specfem_par_acoustic
  use specfem_par_poroelastic
  implicit none

  ! elastic simulations
  if (ELASTIC_SIMULATION) then
    call compute_kernels_el()
  endif

  ! acoustic simulations
  if (ACOUSTIC_SIMULATION) then
    call compute_kernels_ac()
  endif

  ! poroelastic simulations
  if (POROELASTIC_SIMULATION) then
    call compute_kernels_po()
  endif

  ! computes an approximative Hessian for preconditioning kernels
  if (APPROXIMATE_HESS_KL) then
    call compute_kernels_Hessian()
  endif

  end subroutine compute_kernels


!
!-------------------------------------------------------------------------------------------------
!

  subroutine compute_kernels_el()

! elastic kernel calculations
! see e.g. Tromp et al. (2005)

  use specfem_par
  use specfem_par_elastic

  implicit none
  ! local parameters
  integer :: i,j,k,ispec,iglob
  real(kind=CUSTOM_REAL),dimension(21) :: prod
  real(kind=CUSTOM_REAL), dimension(5) :: epsilondev_loc,b_epsilondev_loc

  if (.not. GPU_MODE) then
     ! updates kernels on CPU

     if (ANISOTROPIC_VELOCITY_KL) then

        call compute_anisotropic_kernels_for_velocity_data(b_veloc, b_accel, displ, veloc)

     else

        do ispec = 1, NSPEC_AB

           ! elastic domains
           if (ispec_is_elastic(ispec)) then

              do k = 1, NGLLZ
                 do j = 1, NGLLY
                    do i = 1, NGLLX
                       iglob = ibool(i,j,k,ispec)

                       epsilondev_loc(1) = epsilondev_xx(i,j,k,ispec)
                       epsilondev_loc(2) = epsilondev_yy(i,j,k,ispec)
                       epsilondev_loc(3) = epsilondev_xy(i,j,k,ispec)
                       epsilondev_loc(4) = epsilondev_xz(i,j,k,ispec)
                       epsilondev_loc(5) = epsilondev_yz(i,j,k,ispec)

                       b_epsilondev_loc(1) = b_epsilondev_xx(i,j,k,ispec)
                       b_epsilondev_loc(2) = b_epsilondev_yy(i,j,k,ispec)
                       b_epsilondev_loc(3) = b_epsilondev_xy(i,j,k,ispec)
                       b_epsilondev_loc(4) = b_epsilondev_xz(i,j,k,ispec)
                       b_epsilondev_loc(5) = b_epsilondev_yz(i,j,k,ispec)

                       rho_kl(i,j,k,ispec) =  rho_kl(i,j,k,ispec) &
                            + deltat * dot_product(accel(:,iglob), b_displ(:,iglob))

                       ! For anisotropic kernels
                       if (ANISOTROPIC_KL) then

                          call compute_strain_product(prod,epsilon_trace_over_3(i,j,k,ispec),epsilondev_loc, &
                               b_epsilon_trace_over_3(i,j,k,ispec),b_epsilondev_loc)
                          cijkl_kl(:,i,j,k,ispec) = cijkl_kl(:,i,j,k,ispec) + deltat * prod(:)

                       else

                          ! isotropic kernels
                          ! note: takes displacement from backward/reconstructed (forward) field b_displ
                          !          and acceleration from adjoint field accel (containing adjoint sources)
                          !
                          !          and acceleration from adjoint field accel (containing adjoint sources)
                          !
                          ! note: : time integral summation uses deltat
                          !
                          ! compare with Tromp et al. (2005), eq. (14), which takes adjoint displacement
                          ! and forward acceleration, that is the symmetric form of what is calculated here
                          ! however, this kernel expression is symmetric with regards
                          ! to interchange adjoint - forward field

                          ! kernel for shear modulus, see e.g. Tromp et al. (2005), equation (17)
                          ! note: multiplication with 2*mu(x) will be done after the time loop

                          mu_kl(i,j,k,ispec) =  mu_kl(i,j,k,ispec) &
                               + deltat * (epsilondev_loc(1)*b_epsilondev_loc(1) + epsilondev_loc(2)*b_epsilondev_loc(2) &
                               + (epsilondev_loc(1)+epsilondev_loc(2)) * (b_epsilondev_loc(1)+b_epsilondev_loc(2)) &
                               + 2 * (epsilondev_loc(3)*b_epsilondev_loc(3) + epsilondev_loc(4)*b_epsilondev_loc(4) + &
                               epsilondev_loc(5)*b_epsilondev_loc(5)) )

                          ! kernel for bulk modulus, see e.g. Tromp et al. (2005), equation (18)
                          ! note: multiplication with kappa(x) will be done after the time loop
                          kappa_kl(i,j,k,ispec) = kappa_kl(i,j,k,ispec) &
                               + deltat * (9 * epsilon_trace_over_3(i,j,k,ispec) &
                               * b_epsilon_trace_over_3(i,j,k,ispec))
                       endif
                    enddo
                 enddo
              enddo
           endif !ispec_is_elastic

        enddo

     endif ! anisotropic_velociy_kl


  else
    ! updates kernels on GPU
     call compute_kernels_elastic_cuda(Mesh_pointer,deltat)
  endif

  ! moho kernel
  if (SAVE_MOHO_MESH) then
    if (GPU_MODE) then
      call transfer_accel_from_device(NDIM*NGLOB_AB,accel,Mesh_pointer)
      call transfer_b_displ_from_device(NDIM*NGLOB_AB,b_displ,Mesh_pointer)
    endif
    ! updates on CPU
    call compute_boundary_kernel()
  endif

  ! for noise simulations --- source strength kernel
  if (NOISE_TOMOGRAPHY == 3) then
    call compute_kernels_strength_noise(NGLLSQUARE*num_free_surface_faces,ibool, &
                        sigma_kl,displ,deltat,it, &
                        normal_x_noise,normal_y_noise,normal_z_noise, &
                        noise_surface_movie, &
                        NSPEC_AB,NGLOB_AB, &
                        num_free_surface_faces,free_surface_ispec,free_surface_ijk, &
                        GPU_MODE,Mesh_pointer)
  endif

  end subroutine compute_kernels_el

!
!-------------------------------------------------------------------------------------------------
!

  subroutine compute_kernels_ac()

! acoustic kernel calculations
! see e.g. Tromp et al. (2005)

  use specfem_par
  use specfem_par_acoustic

  implicit none
  ! local parameters
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ):: b_displ_elm,accel_elm
  real(kind=CUSTOM_REAL) :: kappal,rhol
  integer :: i,j,k,ispec,iglob

  ! updates kernels on GPU
  if (GPU_MODE) then

    ! computes contribution to density and bulk modulus kernel
    call compute_kernels_acoustic_cuda(Mesh_pointer,deltat)

    ! kernels are done
    return
  endif

  ! updates kernels
  do ispec = 1, NSPEC_AB

    ! acoustic domains
    if (ispec_is_acoustic(ispec)) then

      ! backward fields: displacement vector
      call compute_gradient_in_acoustic(ispec,NSPEC_ADJOINT,NGLOB_ADJOINT, &
                      b_potential_acoustic, b_displ_elm, &
                      hprime_xx,hprime_yy,hprime_zz, &
                      xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz, &
                      ibool,rhostore,GRAVITY)
      ! adjoint fields: acceleration vector
      ! new expression (\partial_t^2\bfs^\dagger=-\frac{1}{\rho}\bfnabla\phi^\dagger)
      call compute_gradient_in_acoustic(ispec,NSPEC_AB,NGLOB_AB, &
                      potential_acoustic, accel_elm, &
                      hprime_xx,hprime_yy,hprime_zz, &
                      xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz, &
                      ibool,rhostore,GRAVITY)

      do k = 1, NGLLZ
        do j = 1, NGLLY
          do i = 1, NGLLX
            iglob = ibool(i,j,k,ispec)

            ! new expression
            ! density kernel
            rhol = rhostore(i,j,k,ispec)
            rho_ac_kl(i,j,k,ispec) =  rho_ac_kl(i,j,k,ispec) &
                      + deltat * rhol * (accel_elm(1,i,j,k) * b_displ_elm(1,i,j,k) &
                                       + accel_elm(2,i,j,k) * b_displ_elm(2,i,j,k) &
                                       + accel_elm(3,i,j,k) * b_displ_elm(3,i,j,k))

            ! bulk modulus kernel
            kappal = 1._CUSTOM_REAL / kappastore(i,j,k,ispec)
            kappa_ac_kl(i,j,k,ispec) = kappa_ac_kl(i,j,k,ispec) &
                                  + deltat * kappal  &
                                  * potential_acoustic(iglob) &
                                  * b_potential_dot_dot_acoustic(iglob)

          enddo
        enddo
      enddo
    endif ! ispec_is_acoustic

  enddo

  end subroutine compute_kernels_ac

!
!-------------------------------------------------------------------------------------------------
!

  subroutine compute_kernels_po()

! kernel calculations
! see e.g. Morency et al. (2009)

  use specfem_par
  use specfem_par_poroelastic

  implicit none
  ! local parameters
  integer :: i,j,k,ispec,iglob
  real(kind=CUSTOM_REAL), dimension(5) :: epsilonsdev_loc,b_epsilonsdev_loc

  if (.not. GPU_MODE) then
    ! updates kernels on CPU
    do ispec = 1, NSPEC_AB

      ! poroelastic domains
      if (ispec_is_poroelastic(ispec)) then

        do k = 1, NGLLZ
          do j = 1, NGLLY
            do i = 1, NGLLX
              iglob = ibool(i,j,k,ispec)

              ! 8 isotropic kernels
              ! note: takes displacement from backward/reconstructed
              ! (forward) field b_displ
              !          and acceleration from adjoint field accel
              !          (containing adjoint sources)
              !
              ! note: : time integral summation uses deltat
              ! 3 density kernels, see Morency et al. (2009),
              ! equations (39)-(41)
              rhot_kl(i,j,k,ispec) =  rhot_kl(i,j,k,ispec) &
                   + deltat * dot_product(accels_poroelastic(:,iglob), b_displs_poroelastic(:,iglob))

              rhof_kl(i,j,k,ispec) =  rhof_kl(i,j,k,ispec) &
                   + deltat * ( dot_product(accelw_poroelastic(:,iglob), b_displs_poroelastic(:,iglob)) &
                   + dot_product(accels_poroelastic(:,iglob), b_displw_poroelastic(:,iglob)) )

              sm_kl(i,j,k,ispec) =  sm_kl(i,j,k,ispec) &
                   + deltat * dot_product(accelw_poroelastic(:,iglob), b_displw_poroelastic(:,iglob))

              ! kernel for viscous damping, see e.g. Morency et al. (2009),
              ! equation (42)
              eta_kl(i,j,k,ispec) =  eta_kl(i,j,k,ispec) &
                   + deltat * dot_product(velocw_poroelastic(:,iglob), b_displw_poroelastic(:,iglob))

              ! kernel for frame shear modulus, see e.g. Morency et al. (2009),
              ! equation (46)
              ! note: multiplication with 2*mufr(x) will be done after the
              ! time loop
              epsilonsdev_loc(1) = epsilonsdev_xx(i,j,k,ispec)
              epsilonsdev_loc(2) = epsilonsdev_yy(i,j,k,ispec)
              epsilonsdev_loc(3) = epsilonsdev_xy(i,j,k,ispec)
              epsilonsdev_loc(4) = epsilonsdev_xz(i,j,k,ispec)
              epsilonsdev_loc(5) = epsilonsdev_yz(i,j,k,ispec)

              b_epsilonsdev_loc(1) = b_epsilonsdev_xx(i,j,k,ispec)
              b_epsilonsdev_loc(2) = b_epsilonsdev_yy(i,j,k,ispec)
              b_epsilonsdev_loc(3) = b_epsilonsdev_xy(i,j,k,ispec)
              b_epsilonsdev_loc(4) = b_epsilonsdev_xz(i,j,k,ispec)
              b_epsilonsdev_loc(5) = b_epsilonsdev_yz(i,j,k,ispec)

              mufr_kl(i,j,k,ispec) =  mufr_kl(i,j,k,ispec) &
                   + deltat * (epsilonsdev_loc(1)*b_epsilonsdev_loc(1) + epsilonsdev_loc(2)*b_epsilonsdev_loc(2) &
                   + (epsilonsdev_loc(1)+epsilonsdev_loc(2)) * (b_epsilonsdev_loc(1)+b_epsilonsdev_loc(2)) &
                   + 2 * (epsilonsdev_loc(3)*b_epsilonsdev_loc(3) + epsilonsdev_loc(4)*b_epsilonsdev_loc(4) + &
                   epsilonsdev_loc(5)*b_epsilonsdev_loc(5)) )

              ! 3 kernels for the bulk moduli, see e.g. Morency et al. (2009),
              ! equations (43)-(45)
              ! note: multiplication by respective moduli will be done after the
              ! time loop
              B_kl(i,j,k,ispec) = B_kl(i,j,k,ispec) &
                   + deltat * (9 * epsilons_trace_over_3(i,j,k,ispec) &
                   * b_epsilons_trace_over_3(i,j,k,ispec))

              C_kl(i,j,k,ispec) = C_kl(i,j,k,ispec) &
                   + deltat * (9 * epsilons_trace_over_3(i,j,k,ispec) &
                   * b_epsilonw_trace_over_3(i,j,k,ispec) &
                   + 9 * epsilonw_trace_over_3(i,j,k,ispec) &
                   * b_epsilons_trace_over_3(i,j,k,ispec) )

              M_kl(i,j,k,ispec) = M_kl(i,j,k,ispec) &
                   + deltat * (9 * epsilonw_trace_over_3(i,j,k,ispec) &
                   * b_epsilonw_trace_over_3(i,j,k,ispec))
            enddo
          enddo
        enddo
      endif !ispec_is_poroelastic

    enddo

  else
    ! TO DO
    ! updates kernels on GPU
    !call compute_kernels_poroelastic_cuda(Mesh_pointer,deltat)
  endif

  end subroutine compute_kernels_po
!
!-------------------------------------------------------------------------------------------------
!

  subroutine compute_kernels_Hessian()

  use specfem_par
  use specfem_par_elastic
  use specfem_par_acoustic

  implicit none
  ! local parameters
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ):: b_accel_elm,accel_elm,b_veloc_elm
  real(kind=CUSTOM_REAL), dimension(5) :: b_epsilondev_loc
  integer :: i,j,k,ispec,iglob
  real(kind=CUSTOM_REAL) :: kappal,rhol

  ! updates kernels on GPU
  if (GPU_MODE) then

    ! computes contribution to density and bulk modulus kernel
    call compute_kernels_hess_cuda(Mesh_pointer,deltat, &
                                  ELASTIC_SIMULATION,ACOUSTIC_SIMULATION)

    ! done on GPU
    return
  endif

  ! loops over all elements
  do ispec = 1, NSPEC_AB

    ! acoustic domains
    if (ispec_is_acoustic(ispec)) then

      ! adjoint fields: acceleration vector
      call compute_gradient_in_acoustic(ispec,NSPEC_AB,NGLOB_AB, &
                      potential_dot_dot_acoustic, accel_elm, &
                      hprime_xx,hprime_yy,hprime_zz, &
                      xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz, &
                      ibool,rhostore,GRAVITY)

      ! adjoint fields: acceleration vector
      call compute_gradient_in_acoustic(ispec,NSPEC_AB,NGLOB_AB, &
                      b_potential_dot_dot_acoustic, b_accel_elm, &
                      hprime_xx,hprime_yy,hprime_zz, &
                      xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz, &
                      ibool,rhostore,GRAVITY)

      ! backward fields: displacement vector
      call compute_gradient_in_acoustic(ispec,NSPEC_ADJOINT,NGLOB_ADJOINT, &
                      b_potential_dot_acoustic, b_veloc_elm, &
                      hprime_xx,hprime_yy,hprime_zz, &
                      xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz, &
                      ibool,rhostore,GRAVITY)

      do k = 1, NGLLZ
        do j = 1, NGLLY
          do i = 1, NGLLX
            iglob = ibool(i,j,k,ispec)

            ! approximates Hessian
            ! term with adjoint acceleration and backward/reconstructed acceleration
            hess_ac_kl(i,j,k,ispec) =  hess_ac_kl(i,j,k,ispec) &
               + deltat * dot_product(accel_elm(:,i,j,k), b_accel_elm(:,i,j,k))

            rhol = rhostore(i,j,k,ispec)
            hess_rho_ac_kl(i,j,k,ispec) =  hess_rho_ac_kl(i,j,k,ispec) &
                      + deltat * rhol * (b_veloc_elm(1,i,j,k) * b_veloc_elm(1,i,j,k) &
                                       + b_veloc_elm(2,i,j,k) * b_veloc_elm(2,i,j,k) &
                                       + b_veloc_elm(3,i,j,k) * b_veloc_elm(3,i,j,k))

            kappal = 1._CUSTOM_REAL / kappastore(i,j,k,ispec)
            hess_kappa_ac_kl(i,j,k,ispec) = hess_kappa_ac_kl(i,j,k,ispec) &
                                  + deltat * kappal  &
                                  * b_potential_dot_acoustic(iglob) &
                                  * b_potential_dot_acoustic(iglob)

          enddo
        enddo
      enddo
    endif

    ! elastic domains
    if (ispec_is_elastic(ispec)) then
      do k = 1, NGLLZ
        do j = 1, NGLLY
          do i = 1, NGLLX
            iglob = ibool(i,j,k,ispec)

            b_epsilondev_loc(1) = b_epsilondev_xx(i,j,k,ispec)
            b_epsilondev_loc(2) = b_epsilondev_yy(i,j,k,ispec)
            b_epsilondev_loc(3) = b_epsilondev_xy(i,j,k,ispec)
            b_epsilondev_loc(4) = b_epsilondev_xz(i,j,k,ispec)
            b_epsilondev_loc(5) = b_epsilondev_yz(i,j,k,ispec)

            ! approximates Hessian
            ! term with adjoint acceleration and backward/reconstructed acceleration
            hess_kl(i,j,k,ispec) =  hess_kl(i,j,k,ispec) &
               + deltat * dot_product(accel(:,iglob), b_accel(:,iglob))

            !! preconditionning kernels (Shin et al 2001)
            hess_rho_kl(i,j,k,ispec) =  hess_rho_kl(i,j,k,ispec) &
                + deltat * dot_product(b_veloc(:,iglob), b_veloc(:,iglob))

            hess_mu_kl(i,j,k,ispec) = hess_mu_kl(i,j,k,ispec) &
                 + deltat * (b_epsilondev_loc(1)*b_epsilondev_loc(1) + b_epsilondev_loc(2)*b_epsilondev_loc(2) &
                 + (b_epsilondev_loc(1)+b_epsilondev_loc(2)) * (b_epsilondev_loc(1)+b_epsilondev_loc(2)) &
                 + 2 * (b_epsilondev_loc(3)*b_epsilondev_loc(3) + b_epsilondev_loc(4)*b_epsilondev_loc(4) + &
                 b_epsilondev_loc(5)*b_epsilondev_loc(5)) )

            hess_kappa_kl(i,j,k,ispec) = hess_kappa_kl(i,j,k,ispec) &
                     + deltat * (9 * b_epsilon_trace_over_3(i,j,k,ispec) &
                     * b_epsilon_trace_over_3(i,j,k,ispec))

          enddo
        enddo
      enddo
    endif

  enddo

  end subroutine compute_kernels_Hessian

!-------------------------------------------------------------------------------------------------
!
! subroutine to compute the kernels for the 21 elastic coefficients
! Last modified 19/04/2007

!-------------------------------------------------------------------
  subroutine compute_strain_product(prod,eps_trace_over_3,epsdev, &
                          b_eps_trace_over_3,b_epsdev)

  ! Purpose : compute the 21 strain products at a grid point
  ! (ispec,i,j,k fixed) and at a time t to compute then the kernels cij_kl (Voigt notation)
  ! (eq. 15 of Tromp et al., 2005)
  ! prod(1)=eps11*eps11 -> c11, prod(2)=eps11eps22 -> c12, prod(3)=eps11eps33 -> c13, ...
  ! prod(7)=eps22*eps22 -> c22, prod(8)=eps22eps33 -> c23, prod(9)=eps22eps23 -> c24, ...
  ! prod(19)=eps13*eps13 -> c55, prod(20)=eps13eps12 -> c56, prod(21)=eps12eps12 -> c66
  ! This then gives how the 21 kernels are organized
  ! For crust_mantle

  ! Modif 09/11/2005

  use constants

  implicit none

  real(kind=CUSTOM_REAL),dimension(21) :: prod
  real(kind=CUSTOM_REAL) :: eps_trace_over_3,b_eps_trace_over_3
  real(kind=CUSTOM_REAL),dimension(5) :: epsdev,b_epsdev
  real(kind=CUSTOM_REAL), dimension(6) :: eps,b_eps
  integer :: p,i,j

  ! Building of the local matrix of the strain tensor
  ! for the adjoint field and the regular backward field
  eps(1:2)=epsdev(1:2)+eps_trace_over_3           !eps11 et eps22
  eps(3)=-(eps(1)+eps(2))+3*eps_trace_over_3     !eps33
  eps(4)=epsdev(5)                                !eps23
  eps(5)=epsdev(4)                                !eps13
  eps(6)=epsdev(3)                                !eps12

  b_eps(1:2)=b_epsdev(1:2)+b_eps_trace_over_3
  b_eps(3)=-(b_eps(1)+b_eps(2))+3*b_eps_trace_over_3
  b_eps(4)=b_epsdev(5)
  b_eps(5)=b_epsdev(4)
  b_eps(6)=b_epsdev(3)

  ! Computing the 21 strain products without assuming eps(i)*b_eps(j) = eps(j)*b_eps(i)
  p=1
  do i=1,6
    do j=i,6
      prod(p)=eps(i)*b_eps(j)
      if (j > i) then
        prod(p)=prod(p)+eps(j)*b_eps(i)
        if (j > 3 .and. i < 4) prod(p)=prod(p)*2
      endif
      if (i > 3) prod(p)=prod(p)*4
      p=p+1
    enddo
  enddo

  end subroutine compute_strain_product

  subroutine compute_anisotropic_kernels_for_velocity_data(vsem_fwd,asem_fwd,dsem_adj,vsem_adj)

    use specfem_par, only: ngllx, nglly, ngllz, ibool, hprime_xx, hprime_yy, hprime_zz, nspec_ab, &
         xix, xiy, xiz, etax, etay, etaz, gammax, gammay, gammaz, CUSTOM_REAL, &
         nglob_ab, ndim, deltat
    use specfem_par_elastic, only: ispec_is_elastic, rho_kl, cijkl_kl


    real(kind=CUSTOM_REAL), dimension(ndim,nglob_ab), intent(in) :: vsem_fwd, asem_fwd
    real(kind=CUSTOM_REAL), dimension(ndim,nglob_ab), intent(in) :: dsem_adj, vsem_adj

    integer                :: i, j, k, ielem, iglob   ! ,l

    real(kind=CUSTOM_REAL) :: dxil_dxl, dxil_dyl, dxil_dzl
    real(kind=CUSTOM_REAL) :: detal_dxl, detal_dyl, detal_dzl
    real(kind=CUSTOM_REAL) :: dgaml_dxl, dgaml_dyl, dgaml_dzl

    real(kind=CUSTOM_REAL) :: dux_dxil, dux_detal, dux_dgaml
    real(kind=CUSTOM_REAL) :: duy_dxil, duy_detal, duy_dgaml
    real(kind=CUSTOM_REAL) :: duz_dxil, duz_detal, duz_dgaml

    real(kind=CUSTOM_REAL) :: dvx_dxil, dvx_detal, dvx_dgaml
    real(kind=CUSTOM_REAL) :: dvy_dxil, dvy_detal, dvy_dgaml
    real(kind=CUSTOM_REAL) :: dvz_dxil, dvz_detal, dvz_dgaml

    real(kind=CUSTOM_REAL) :: dux_dxl, dux_dyl, dux_dzl
    real(kind=CUSTOM_REAL) :: duy_dxl, duy_dyl, duy_dzl
    real(kind=CUSTOM_REAL) :: duz_dxl, duz_dyl, duz_dzl
    real(kind=CUSTOM_REAL) :: dux_dyl_plus_duy_dxl
    real(kind=CUSTOM_REAL) :: duz_dxl_plus_dux_dzl, duz_dyl_plus_duy_dzl

    real(kind=CUSTOM_REAL) :: dvx_dxl, dvx_dyl, dvx_dzl
    real(kind=CUSTOM_REAL) :: dvy_dxl, dvy_dyl, dvy_dzl
    real(kind=CUSTOM_REAL) :: dvz_dxl, dvz_dyl, dvz_dzl
    real(kind=CUSTOM_REAL) :: dvx_dyl_plus_dvy_dxl
    real(kind=CUSTOM_REAL) :: dvz_dxl_plus_dvx_dzl, dvz_dyl_plus_dvy_dzl

    real(kind=CUSTOM_REAL) :: fac

    real(kind=CUSTOM_REAL), dimension(3,ngllx,nglly,ngllz) :: vadj_gll, afwd_gll
    real(kind=CUSTOM_REAL), dimension(3,ngllx,nglly,ngllz) :: vsem_fwd_gll, dsem_adj_gll

    !*** Loop over GLL points
    do ielem=1,nspec_ab

       if (ispec_is_elastic(ielem)) then

          !*** Real first loop for optim
          do k=1,ngllz
             do j=1,nglly
                do i=1,ngllx

                   iglob  = ibool(i,j,k,ielem)    ! find global index

                   vadj_gll(1,i,j,k) = vsem_adj(1,iglob)
                   vadj_gll(2,i,j,k) = vsem_adj(2,iglob)
                   vadj_gll(3,i,j,k) = vsem_adj(3,iglob)

                   afwd_gll(1,i,j,k) = asem_fwd(1,iglob)
                   afwd_gll(2,i,j,k) = asem_fwd(2,iglob)
                   afwd_gll(3,i,j,k) = asem_fwd(3,iglob)

                   dsem_adj_gll(1,i,j,k) = dsem_adj(1,iglob)
                   dsem_adj_gll(2,i,j,k) = dsem_adj(2,iglob)
                   dsem_adj_gll(3,i,j,k) = dsem_adj(3,iglob)

                   vsem_fwd_gll(1,i,j,k) = vsem_fwd(1,iglob)
                   vsem_fwd_gll(2,i,j,k) = vsem_fwd(2,iglob)
                   vsem_fwd_gll(3,i,j,k) = vsem_fwd(3,iglob)

                enddo
             enddo
          enddo

          do k=1,ngllz
             do j=1,nglly
                do i=1,ngllx

                   !================================================================
                   ! Compute strain related terms (adjoit strain and time der of normal strain)
                   !*** Init derivatives to 0
                   !* Normal
                   dvx_dxil  = 0._CUSTOM_REAL
                   dvx_detal = 0._CUSTOM_REAL
                   dvx_dgaml = 0._CUSTOM_REAL
                   dvy_dxil  = 0._CUSTOM_REAL
                   dvy_detal = 0._CUSTOM_REAL
                   dvy_dgaml = 0._CUSTOM_REAL
                   dvz_dxil  = 0._CUSTOM_REAL
                   dvz_detal = 0._CUSTOM_REAL
                   dvz_dgaml = 0._CUSTOM_REAL

                   !* Adjoint
                   dux_dxil  = 0._CUSTOM_REAL
                   dux_detal = 0._CUSTOM_REAL
                   dux_dgaml = 0._CUSTOM_REAL
                   duy_dxil  = 0._CUSTOM_REAL
                   duy_detal = 0._CUSTOM_REAL
                   duy_dgaml = 0._CUSTOM_REAL
                   duz_dxil  = 0._CUSTOM_REAL
                   duz_detal = 0._CUSTOM_REAL
                   duz_dgaml = 0._CUSTOM_REAL

                   !*** Field derivatives wrt xi
                   fac = hprime_xx(1,i)          ! derivative of lacal lagrange polynomials
                   dvx_dxil = dvx_dxil + vsem_fwd_gll(1,1,j,k) * fac
                   dvy_dxil = dvy_dxil + vsem_fwd_gll(2,1,j,k) * fac
                   dvz_dxil = dvz_dxil + vsem_fwd_gll(3,1,j,k) * fac
                   dux_dxil = dux_dxil + dsem_adj_gll(1,1,j,k) * fac
                   duy_dxil = duy_dxil + dsem_adj_gll(2,1,j,k) * fac
                   duz_dxil = duz_dxil + dsem_adj_gll(3,1,j,k) * fac

                   fac = hprime_xx(2,i)          ! derivative of lacal lagrange polynomials
                   dvx_dxil = dvx_dxil + vsem_fwd_gll(1,2,j,k) * fac
                   dvy_dxil = dvy_dxil + vsem_fwd_gll(2,2,j,k) * fac
                   dvz_dxil = dvz_dxil + vsem_fwd_gll(3,2,j,k) * fac
                   dux_dxil = dux_dxil + dsem_adj_gll(1,2,j,k) * fac
                   duy_dxil = duy_dxil + dsem_adj_gll(2,2,j,k) * fac
                   duz_dxil = duz_dxil + dsem_adj_gll(3,2,j,k) * fac

                   fac = hprime_xx(3,i)          ! derivative of lacal lagrange polynomials
                   dvx_dxil = dvx_dxil + vsem_fwd_gll(1,3,j,k) * fac
                   dvy_dxil = dvy_dxil + vsem_fwd_gll(2,3,j,k) * fac
                   dvz_dxil = dvz_dxil + vsem_fwd_gll(3,3,j,k) * fac
                   dux_dxil = dux_dxil + dsem_adj_gll(1,3,j,k) * fac
                   duy_dxil = duy_dxil + dsem_adj_gll(2,3,j,k) * fac
                   duz_dxil = duz_dxil + dsem_adj_gll(3,3,j,k) * fac

                   fac = hprime_xx(4,i)          ! derivative of lacal lagrange polynomials
                   dvx_dxil = dvx_dxil + vsem_fwd_gll(1,4,j,k) * fac
                   dvy_dxil = dvy_dxil + vsem_fwd_gll(2,4,j,k) * fac
                   dvz_dxil = dvz_dxil + vsem_fwd_gll(3,4,j,k) * fac
                   dux_dxil = dux_dxil + dsem_adj_gll(1,4,j,k) * fac
                   duy_dxil = duy_dxil + dsem_adj_gll(2,4,j,k) * fac
                   duz_dxil = duz_dxil + dsem_adj_gll(3,4,j,k) * fac

                   fac = hprime_xx(5,i)          ! derivative of lacal lagrange polynomials
                   dvx_dxil = dvx_dxil + vsem_fwd_gll(1,5,j,k) * fac
                   dvy_dxil = dvy_dxil + vsem_fwd_gll(2,5,j,k) * fac
                   dvz_dxil = dvz_dxil + vsem_fwd_gll(3,5,j,k) * fac
                   dux_dxil = dux_dxil + dsem_adj_gll(1,5,j,k) * fac
                   duy_dxil = duy_dxil + dsem_adj_gll(2,5,j,k) * fac
                   duz_dxil = duz_dxil + dsem_adj_gll(3,5,j,k) * fac

                   !*** Field derivatives wrt eta
                   fac = hprime_yy(1,j)         ! derivative of local lageange polynomials
                   dvx_detal = dvx_detal + vsem_fwd_gll(1,i,1,k) * fac
                   dvy_detal = dvy_detal + vsem_fwd_gll(2,i,1,k) * fac
                   dvz_detal = dvz_detal + vsem_fwd_gll(3,i,1,k) * fac
                   dux_detal = dux_detal + dsem_adj_gll(1,i,1,k) * fac
                   duy_detal = duy_detal + dsem_adj_gll(2,i,1,k) * fac
                   duz_detal = duz_detal + dsem_adj_gll(3,i,1,k) * fac

                   fac = hprime_yy(2,j)         ! derivative of local lageange polynomials
                   dvx_detal = dvx_detal + vsem_fwd_gll(1,i,2,k) * fac
                   dvy_detal = dvy_detal + vsem_fwd_gll(2,i,2,k) * fac
                   dvz_detal = dvz_detal + vsem_fwd_gll(3,i,2,k) * fac
                   dux_detal = dux_detal + dsem_adj_gll(1,i,2,k) * fac
                   duy_detal = duy_detal + dsem_adj_gll(2,i,2,k) * fac
                   duz_detal = duz_detal + dsem_adj_gll(3,i,2,k) * fac

                   fac = hprime_yy(3,j)         ! derivative of local lageange polynomials
                   dvx_detal = dvx_detal + vsem_fwd_gll(1,i,3,k) * fac
                   dvy_detal = dvy_detal + vsem_fwd_gll(2,i,3,k) * fac
                   dvz_detal = dvz_detal + vsem_fwd_gll(3,i,3,k) * fac
                   dux_detal = dux_detal + dsem_adj_gll(1,i,3,k) * fac
                   duy_detal = duy_detal + dsem_adj_gll(2,i,3,k) * fac
                   duz_detal = duz_detal + dsem_adj_gll(3,i,3,k) * fac

                   fac = hprime_yy(4,j)         ! derivative of local lageange polynomials
                   dvx_detal = dvx_detal + vsem_fwd_gll(1,i,4,k) * fac
                   dvy_detal = dvy_detal + vsem_fwd_gll(2,i,4,k) * fac
                   dvz_detal = dvz_detal + vsem_fwd_gll(3,i,4,k) * fac
                   dux_detal = dux_detal + dsem_adj_gll(1,i,4,k) * fac
                   duy_detal = duy_detal + dsem_adj_gll(2,i,4,k) * fac
                   duz_detal = duz_detal + dsem_adj_gll(3,i,4,k) * fac

                   fac = hprime_yy(5,j)         ! derivative of local lageange polynomials
                   dvx_detal = dvx_detal + vsem_fwd_gll(1,i,5,k) * fac
                   dvy_detal = dvy_detal + vsem_fwd_gll(2,i,5,k) * fac
                   dvz_detal = dvz_detal + vsem_fwd_gll(3,i,5,k) * fac
                   dux_detal = dux_detal + dsem_adj_gll(1,i,5,k) * fac
                   duy_detal = duy_detal + dsem_adj_gll(2,i,5,k) * fac
                   duz_detal = duz_detal + dsem_adj_gll(3,i,5,k) * fac

                   !*** Field derivatives wrt gamma
                   fac = hprime_zz(1,k)         ! derivative of local lagange polynomials
                   dvx_dgaml = dvx_dgaml + vsem_fwd_gll(1,i,j,1) * fac
                   dvy_dgaml = dvy_dgaml + vsem_fwd_gll(2,i,j,1) * fac
                   dvz_dgaml = dvz_dgaml + vsem_fwd_gll(3,i,j,1) * fac
                   dux_dgaml = dux_dgaml + dsem_adj_gll(1,i,j,1) * fac
                   duy_dgaml = duy_dgaml + dsem_adj_gll(2,i,j,1) * fac
                   duz_dgaml = duz_dgaml + dsem_adj_gll(3,i,j,1) * fac

                   fac = hprime_zz(2,k)         ! derivative of local lagange polynomials
                   dvx_dgaml = dvx_dgaml + vsem_fwd_gll(1,i,j,2) * fac
                   dvy_dgaml = dvy_dgaml + vsem_fwd_gll(2,i,j,2) * fac
                   dvz_dgaml = dvz_dgaml + vsem_fwd_gll(3,i,j,2) * fac
                   dux_dgaml = dux_dgaml + dsem_adj_gll(1,i,j,2) * fac
                   duy_dgaml = duy_dgaml + dsem_adj_gll(2,i,j,2) * fac
                   duz_dgaml = duz_dgaml + dsem_adj_gll(3,i,j,2) * fac

                   fac = hprime_zz(3,k)         ! derivative of local lagange polynomials
                   dvx_dgaml = dvx_dgaml + vsem_fwd_gll(1,i,j,3) * fac
                   dvy_dgaml = dvy_dgaml + vsem_fwd_gll(2,i,j,3) * fac
                   dvz_dgaml = dvz_dgaml + vsem_fwd_gll(3,i,j,3) * fac
                   dux_dgaml = dux_dgaml + dsem_adj_gll(1,i,j,3) * fac
                   duy_dgaml = duy_dgaml + dsem_adj_gll(2,i,j,3) * fac
                   duz_dgaml = duz_dgaml + dsem_adj_gll(3,i,j,3) * fac

                   fac = hprime_zz(4,k)         ! derivative of local lagange polynomials
                   dvx_dgaml = dvx_dgaml + vsem_fwd_gll(1,i,j,4) * fac
                   dvy_dgaml = dvy_dgaml + vsem_fwd_gll(2,i,j,4) * fac
                   dvz_dgaml = dvz_dgaml + vsem_fwd_gll(3,i,j,4) * fac
                   dux_dgaml = dux_dgaml + dsem_adj_gll(1,i,j,4) * fac
                   duy_dgaml = duy_dgaml + dsem_adj_gll(2,i,j,4) * fac
                   duz_dgaml = duz_dgaml + dsem_adj_gll(3,i,j,4) * fac

                   fac = hprime_zz(5,k)         ! derivative of local lagange polynomials
                   dvx_dgaml = dvx_dgaml + vsem_fwd_gll(1,i,j,5) * fac
                   dvy_dgaml = dvy_dgaml + vsem_fwd_gll(2,i,j,5) * fac
                   dvz_dgaml = dvz_dgaml + vsem_fwd_gll(3,i,j,5) * fac
                   dux_dgaml = dux_dgaml + dsem_adj_gll(1,i,j,5) * fac
                   duy_dgaml = duy_dgaml + dsem_adj_gll(2,i,j,5) * fac
                   duz_dgaml = duz_dgaml + dsem_adj_gll(3,i,j,5) * fac

                   !*** Get local derivatives of ref square coord wrt Cartesian ones (jacobian)
                   dxil_dxl  = xix(i,j,k,ielem)
                   dxil_dyl  = xiy(i,j,k,ielem)
                   dxil_dzl  = xiz(i,j,k,ielem)
                   detal_dxl = etax(i,j,k,ielem)
                   detal_dyl = etay(i,j,k,ielem)
                   detal_dzl = etaz(i,j,k,ielem)
                   dgaml_dxl = gammax(i,j,k,ielem)
                   dgaml_dyl = gammay(i,j,k,ielem)
                   dgaml_dzl = gammaz(i,j,k,ielem)

                   !*** Strain
                   !* Normal state normal strain
                   dvx_dxl = dvx_dxil * dxil_dxl + dvx_detal * detal_dxl + dvx_dgaml * dgaml_dxl
                   dvx_dyl = dvx_dxil * dxil_dyl + dvx_detal * detal_dyl + dvx_dgaml * dgaml_dyl
                   dvx_dzl = dvx_dxil * dxil_dzl + dvx_detal * detal_dzl + dvx_dgaml * dgaml_dzl
                   dvy_dxl = dvy_dxil * dxil_dxl + dvy_detal * detal_dxl + dvy_dgaml * dgaml_dxl
                   dvy_dyl = dvy_dxil * dxil_dyl + dvy_detal * detal_dyl + dvy_dgaml * dgaml_dyl
                   dvy_dzl = dvy_dxil * dxil_dzl + dvy_detal * detal_dzl + dvy_dgaml * dgaml_dzl
                   dvz_dxl = dvz_dxil * dxil_dxl + dvz_detal * detal_dxl + dvz_dgaml * dgaml_dxl
                   dvz_dyl = dvz_dxil * dxil_dyl + dvz_detal * detal_dyl + dvz_dgaml * dgaml_dyl
                   dvz_dzl = dvz_dxil * dxil_dzl + dvz_detal * detal_dzl + dvz_dgaml * dgaml_dzl

                   !* Adjoint state normal strain
                   dux_dxl = dux_dxil * dxil_dxl + dux_detal * detal_dxl + dux_dgaml * dgaml_dxl
                   dux_dyl = dux_dxil * dxil_dyl + dux_detal * detal_dyl + dux_dgaml * dgaml_dyl
                   dux_dzl = dux_dxil * dxil_dzl + dux_detal * detal_dzl + dux_dgaml * dgaml_dzl
                   duy_dxl = duy_dxil * dxil_dxl + duy_detal * detal_dxl + duy_dgaml * dgaml_dxl
                   duy_dyl = duy_dxil * dxil_dyl + duy_detal * detal_dyl + duy_dgaml * dgaml_dyl
                   duy_dzl = duy_dxil * dxil_dzl + duy_detal * detal_dzl + duy_dgaml * dgaml_dzl
                   duz_dxl = duz_dxil * dxil_dxl + duz_detal * detal_dxl + duz_dgaml * dgaml_dxl
                   duz_dyl = duz_dxil * dxil_dyl + duz_detal * detal_dyl + duz_dgaml * dgaml_dyl
                   duz_dzl = duz_dxil * dxil_dzl + duz_detal * detal_dzl + duz_dgaml * dgaml_dzl

                   !* Normal state non normal strain
                   dvx_dyl_plus_dvy_dxl = dvx_dyl + dvy_dxl
                   dvz_dxl_plus_dvx_dzl = dvz_dxl + dvx_dzl
                   dvz_dyl_plus_dvy_dzl = dvz_dyl + dvy_dzl

                   !* Adjoint state non normal strain
                   dux_dyl_plus_duy_dxl = dux_dyl + duy_dxl
                   duz_dxl_plus_dux_dzl = duz_dxl + dux_dzl
                   duz_dyl_plus_duy_dzl = duz_dyl + duy_dzl


                   !===========================================================================
                   ! Gradient
                   rho_kl(i,j,k,ielem) = rho_kl(i,j,k,ielem) &
                        + (afwd_gll(1,i,j,k) * vadj_gll(1,i,j,k) &
                        +  afwd_gll(2,i,j,k) * vadj_gll(2,i,j,k) &
                        +  afwd_gll(3,i,j,k) * vadj_gll(3,i,j,k))*deltat

                   !*** Gradient wrt c_ij
                   !* c11
                   cijkl_kl(1,i,j,k,ielem) = cijkl_kl(1,i,j,k,ielem) + dvx_dxl*dux_dxl*deltat

                   !* c12
                   cijkl_kl(2,i,j,k,ielem) = cijkl_kl(2,i,j,k,ielem) &
                        +(dvx_dxl * duy_dyl + dvy_dyl * dux_dxl)*deltat

                   !* c13
                   cijkl_kl(3,i,j,k,ielem) = cijkl_kl(3,i,j,k,ielem) &
                        +(dvx_dxl * duz_dzl + dvz_dzl * dux_dxl)*deltat

                   !* c14
                   cijkl_kl(4,i,j,k,ielem) = cijkl_kl(4,i,j,k,ielem) &
                        +(dvx_dxl * duz_dyl_plus_duy_dzl + dvz_dyl_plus_dvy_dzl * dux_dxl)*deltat

                   !* c15
                   cijkl_kl(5,i,j,k,ielem) = cijkl_kl(5,i,j,k,ielem) &
                        +(dvx_dxl * duz_dxl_plus_dux_dzl + dvz_dxl_plus_dvx_dzl * dux_dxl)*deltat

                   !* c16
                   cijkl_kl(6,i,j,k,ielem) = cijkl_kl(6,i,j,k,ielem) &
                        +(dvx_dxl * dux_dyl_plus_duy_dxl + dvx_dyl_plus_dvy_dxl * dux_dxl)*deltat

                   !* c22
                   cijkl_kl(7,i,j,k,ielem) = cijkl_kl(7,i,j,k,ielem) + dvy_dyl*duy_dyl*deltat

                   !* c23
                   cijkl_kl(8,i,j,k,ielem) = cijkl_kl(8,i,j,k,ielem) &
                        +(dvy_dyl * duz_dzl + dvz_dzl * duy_dyl)*deltat

                   !* c24
                   cijkl_kl(9,i,j,k,ielem) = cijkl_kl(9,i,j,k,ielem) &
                        +(dvy_dyl * duz_dyl_plus_duy_dzl + dvz_dyl_plus_dvy_dzl * duy_dyl)*deltat

                   !* c25
                   cijkl_kl(10,i,j,k,ielem) = cijkl_kl(10,i,j,k,ielem) &
                        +(dvy_dyl * duz_dxl_plus_dux_dzl + dvz_dxl_plus_dvx_dzl * duy_dyl)*deltat

                   !* c26
                   cijkl_kl(11,i,j,k,ielem) = cijkl_kl(11,i,j,k,ielem) &
                        +(dvy_dyl * dux_dyl_plus_duy_dxl + dvx_dyl_plus_dvy_dxl * duy_dyl)*deltat

                   !* c33
                   cijkl_kl(12,i,j,k,ielem) = cijkl_kl(12,i,j,k,ielem) + dvz_dzl*duz_dzl*deltat

                   !* c34
                   cijkl_kl(13,i,j,k,ielem) = cijkl_kl(13,i,j,k,ielem) &
                        +(dvz_dzl * duz_dyl_plus_duy_dzl + dvz_dyl_plus_dvy_dzl * duz_dzl)*deltat

                   !* c35
                   cijkl_kl(14,i,j,k,ielem) = cijkl_kl(14,i,j,k,ielem) &
                        +(dvz_dzl * duz_dxl_plus_dux_dzl + dvz_dxl_plus_dvx_dzl * duz_dzl)*deltat

                   !* c36
                   cijkl_kl(15,i,j,k,ielem) = cijkl_kl(15,i,j,k,ielem) &
                        +(dvz_dzl * dux_dyl_plus_duy_dxl + dvx_dyl_plus_dvy_dxl * duz_dzl)*deltat

                   !* c44
                   cijkl_kl(16,i,j,k,ielem) = cijkl_kl(16,i,j,k,ielem) &
                        + dvz_dyl_plus_dvy_dzl * duz_dyl_plus_duy_dzl*deltat

                   !* c45
                   cijkl_kl(17,i,j,k,ielem) = cijkl_kl(17,i,j,k,ielem) &
                        +(dvz_dyl_plus_dvy_dzl * duz_dxl_plus_dux_dzl &
                        + dvz_dxl_plus_dvx_dzl * duz_dyl_plus_duy_dzl)*deltat

                   !* c46
                   cijkl_kl(18,i,j,k,ielem) = cijkl_kl(18,i,j,k,ielem) &
                        +(dvz_dyl_plus_dvy_dzl * dux_dyl_plus_duy_dxl &
                        + dvx_dyl_plus_dvy_dxl * duz_dyl_plus_duy_dzl)*deltat

                   !* c55
                   cijkl_kl(19,i,j,k,ielem) = cijkl_kl(19,i,j,k,ielem) &
                        + dvz_dxl_plus_dvx_dzl * duz_dxl_plus_dux_dzl*deltat

                   !* c56
                   cijkl_kl(20,i,j,k,ielem) = cijkl_kl(20,i,j,k,ielem) &
                        +(dvz_dxl_plus_dvx_dzl * dux_dyl_plus_duy_dxl &
                        + dvx_dyl_plus_dvy_dxl * duz_dxl_plus_dux_dzl)*deltat

                   !* c66
                   cijkl_kl(21,i,j,k,ielem) = cijkl_kl(21,i,j,k,ielem) &
                        + dvx_dyl_plus_dvy_dxl * dux_dyl_plus_duy_dxl*deltat
                enddo
             enddo
          enddo

       endif ! ispec_is_elastic

    enddo

  end subroutine compute_anisotropic_kernels_for_velocity_data
